#!/usr/bin/env python3
"""Upload a file to running FPGA Linux with BusyBox rx and the retained UART reader.

The UART stays at 115200. Pause other console writers during the transfer.
Only a verified file replaces the destination; the reader handle stays open.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import select
import sys
import termios
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'triangulator'))
from uart_link import UartWriter
from xmodem import Sender, TransferError, ACK, NAK, CAN, CRC_REQUEST


class RawLogTail:
    """Read protocol replies from the existing reader's raw log, never the UART."""
    def __init__(self, path):
        self.file = Path(path).open('rb')
        self.file.seek(0, os.SEEK_END)
        self.history = bytearray()
        self.cursor = 0

    def pump(self):
        self.history.extend(self.file.read(65536))
        if len(self.history) > 2 * 1024 * 1024:
            raise TransferError('unexpectedly large UART transcript during upload')

    def match(self, pattern):
        self.pump()
        return re.search(pattern, self.history)

    def wait(self, pattern, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            found = self.match(pattern)
            if found:
                self.cursor = max(self.cursor, found.end())
                return found
            time.sleep(0.01)
        raise TransferError(f'timeout waiting for target marker {pattern!r}')

    def control(self, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.pump()
            while self.cursor < len(self.history):
                value = self.history[self.cursor]
                self.cursor += 1
                if value in (ACK, NAK, CAN, CRC_REQUEST):
                    return value
            time.sleep(0.005)
        return None

    def close(self):
        self.file.close()


def marker(text):
    # Do not mistake an echoed printf command for its actual output.
    return rb'(?:^|[\r\n])' + re.escape(text.encode()) + rb'(?=\r?\n)'


def write_bursts(fd, data, burst_bytes, burst_delay):
    for offset in range(0, len(data), burst_bytes):
        pending = memoryview(data)[offset:offset + burst_bytes]
        deadline = time.monotonic() + 10
        while pending:
            try:
                written = os.write(fd, pending)
                if not written:
                    raise TransferError('UART write made no progress')
                pending = pending[written:]
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TransferError('UART write timeout')
                select.select([], [fd], [], 0.02)
        if burst_delay:
            time.sleep(burst_delay)


def transfer(writer, tail, data, destination, burst_bytes=8, burst_delay=0.002,
             timeout=0.4, retries=5, busybox='/bin/busybox', progress=None):
    token = uuid.uuid4().hex[:12]
    part = f'{destination}.s32-{token}.part'
    exact = part + '.exact'
    digest = hashlib.sha256(data).hexdigest()
    prepared = f'S32_RX_PREPARED_{token}'
    begin = f'S32_RX_BEGIN_{token}'
    done_pattern = rb'(?:^|[\r\n])S32_RX_DONE_' + token.encode() + rb':([0-9]+)(?=\r?\n)'
    verified = f'S32_RX_VERIFIED_{token}'
    failed = f'S32_RX_FAILED_{token}'
    recovered = f'S32_UART_RECOVERED:{token}:0'
    receiver_started = False
    error = None
    result = None

    def command(text):
        writer.send((text + '\n').encode(), 0.001)

    def abort_receiver():
        # BusyBox rx uses cfmakeraw (no Ctrl+C) and does not implement sender-CAN
        # abort. One invalid start byte per NAK consumes its bounded error budget.
        # First allow a partial packet's one-second read timeout to resynchronize.
        if tail.match(done_pattern):
            return
        tail.control(1.2)
        for _ in range(12):
            if tail.match(done_pattern):
                return
            write_bursts(writer.fd, bytes([CAN]), 1, 0)
            reply = tail.control(1.5)
            if reply == CAN:
                tail.wait(done_pattern, 10)
                return
        tail.wait(done_pattern, 5)

    try:
        command(f'S32_RX_TTY=$({busybox} stty -g) && '
                'read S32_RX_LEVEL S32_RX_UNUSED < /proc/sys/kernel/printk && '
                f'{busybox} stty -echo && {busybox} dmesg -n 5 && '
                f"printf '\\n{prepared}\\n'")
        tail.wait(marker(prepared))
        command(f"printf '\\n{begin}\\n'; {busybox} rx {part}; "
                "S32_RX_RC=$?; "
                f"printf '\\nS32_RX_DONE_{token}:%s\\n' \"$S32_RX_RC\"")
        receiver_started = True
        tail.wait(marker(begin))
        sender = Sender(lambda packet: write_bursts(writer.fd, packet, burst_bytes, burst_delay),
                        tail.control, timeout, retries)
        result = sender.send(data, progress)
        done = tail.wait(done_pattern)
        receiver_started = False
        # BusyBox1.36.1 rx exits with (n >= 0), reversing conventional status.
        # Require the completed CRC/EOT protocol and exact size/SHA below;
        # accept its historical success1 as well as a corrected receiver's0.
        receiver_status = int(done.group(1))
        if receiver_status not in (0, 1):
            raise TransferError(f'BusyBox rx exited with status {receiver_status}')
        result['receiver_exit_code'] = receiver_status
        # Keep both staging names beside the destination, so the final rename is
        # atomic. Failed transfer/size/hash checks never replace an existing file.
        command(f'if {busybox} head -c {len(data)} {part} > {exact} && '
                f'[ "$({busybox} wc -c < {exact})" = {len(data)} ] && '
                f'S32_RX_HASH=$({busybox} sha256sum {exact}) && '
                f'[ "${{S32_RX_HASH%% *}}" = {digest} ] && '
                f'{busybox} mv -f {exact} {destination}; then '
                f'{busybox} rm -f {part}; printf \'\\n{verified}\\n\'; else '
                f'{busybox} rm -f {part} {exact}; printf \'\\n{failed}\\n\'; fi')
        found = tail.wait(rb'(?:^|[\r\n])(?:' + verified.encode() + b'|' + failed.encode() + rb')(?=\r?\n)')
        if verified.encode() not in found.group():
            raise TransferError('target exact-size/SHA256/rename verification failed')
        result.update({'sha256': digest, 'destination': destination, 'verified': True})
    except BaseException as caught:
        error = caught
    finally:
        try:
            if receiver_started:
                abort_receiver()
            command(f'{busybox} rm -f {part} {exact}; '
                    f'if [ -n "${{S32_RX_TTY:-}}" ]; then {busybox} stty "$S32_RX_TTY"; fi && '
                    f'{busybox} stty 115200 && '
                    f'if [ -n "${{S32_RX_LEVEL:-}}" ]; then {busybox} dmesg -n "$S32_RX_LEVEL"; fi && '
                    'unset S32_RX_TTY S32_RX_LEVEL S32_RX_UNUSED S32_RX_HASH S32_RX_RC && '
                    f"printf '\\n{recovered}\\n'")
            tail.wait(marker(recovered))
            if termios.tcgetattr(writer.fd)[4:6] != [termios.B115200] * 2:
                raise TransferError('host UART did not remain at 115200')
            print('S32_UART_RECOVERED: reader retained, console restored at 115200', flush=True)
        except BaseException as restore_error:
            if error is not None:
                raise TransferError(f'{error}; console recovery was not verified: {restore_error}') from restore_error
            raise
    if error is not None:
        raise error
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('port')
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--destination', required=True)
    parser.add_argument('--burst-bytes', type=int, default=8)
    parser.add_argument('--burst-delay', type=float, default=0.002)
    parser.add_argument('--ack-timeout', type=float, default=0.4,
                        help="Data ACK timeout, below rx's one-second idle timeout (default:0.4)")
    parser.add_argument('--retries', type=int, default=5)
    args = parser.parse_args()
    if not re.fullmatch(r'/[A-Za-z0-9_./-]+', args.destination):
        parser.error('--destination must be an absolute path without shell characters')
    if not 1 <= args.burst_bytes <= 1024 or not 0 <= args.burst_delay <= 0.1:
        parser.error('burst bytes must be 1..1024 and delay 0..0.1 seconds')
    if not 0.05 <= args.ack_timeout <= 0.75 or not 0 <= args.retries <= 8:
        parser.error('ACK timeout must be 0.05..0.75 seconds and retries 0..8')
    data = args.binary.read_bytes()
    tail = RawLogTail(args.log)
    writer = None
    try:
        writer = UartWriter(args.port)
        last = [0.0]
        def progress(sent, total, retransmissions):
            now = time.monotonic()
            if now - last[0] >= 5 or sent == total:
                print(f'Uploaded {sent}/{total} bytes; retransmissions={retransmissions}', flush=True)
                last[0] = now
        result = transfer(writer, tail, data, args.destination, args.burst_bytes,
                          args.burst_delay, args.ack_timeout, args.retries, progress=progress)
        print(f"Verified {result['destination']}: SHA256 {result['sha256']}; "
              f"{result['elapsed_seconds']:.2f}seconds", flush=True)
        return 0
    except (OSError, RuntimeError) as error:
        print(f'Upload failed: {error}', file=sys.stderr)
        return 1
    finally:
        if writer is not None:
            writer.close()
        tail.close()


if __name__ == '__main__':
    raise SystemExit(main())
