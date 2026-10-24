#!/usr/bin/env python3
"""Upload Linux, capture the physical UART, and verify a shell command."""
import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

from upload import frame


class RebootDetector:
    """Recognize a complete kernel restart record, including split UART reads."""
    pattern = re.compile(rb'^\[\s*\d+\.\d+\] reboot: Restarting system\s*$')

    def __init__(self):
        self.pending = b''

    def feed(self, data):
        records = (self.pending + data).split(b'\n')
        self.pending = records.pop()[-4096:]
        return any(self.pattern.fullmatch(record.strip(b'\r')) for record in records)


def program_bitstream(bitstream, log_path, vivado='vivado'):
    """Program once before opening UART; software reboot needs no JTAG cycle."""
    bitstream = Path(bitstream).resolve()
    if not bitstream.is_file():
        raise RuntimeError(f'Bitstream does not exist: {bitstream}')
    log_path = Path(log_path)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    print(f'Programming {bitstream}', flush=True)
    with log_path.open('wb') as output:
        subprocess.run([vivado, '-mode', 'batch', '-nojournal', '-log',
                        str(log_path.with_suffix('.vivado.log')), '-source',
                        str(Path(__file__).with_name('program.tcl')), '-tclargs', str(bitstream)],
                       stdout=output, stderr=subprocess.STDOUT, check=True)


def capture_once(args, packet, port):
    """One loader/console cycle using an already-open, exclusively held UART."""
    port.baudrate = args.console_baud if packet is None else args.baud
    time.sleep(1)
    port.reset_input_buffer()
    pending_console = b''
    if packet is not None:
        start = last = time.monotonic()
        print(f'Uploading {len(packet)-12:,} bytes at {args.baud} baud', flush=True)
        received = bytearray()
        for offset in range(0, len(packet), 16384):
            block = packet[offset:offset+16384]
            if port.write(block) != len(block):
                raise RuntimeError('Short serial write')
            if port.in_waiting:
                received.extend(port.read(port.in_waiting))
                if received[0] == ord('E'):
                    raise RuntimeError(f'Loader rejected transfer after {offset+len(block):,} bytes')
            now = time.monotonic()
            if now-last >= 5:
                print(f'{min(offset+len(block),len(packet))*100/len(packet):.1f}% elapsed={now-start:.1f}s', flush=True)
                last = now
        port.flush()
        deadline = time.monotonic()+10
        while not received and time.monotonic() < deadline:
            received.extend(port.read(1))
        print(f'Loader reply={bytes(received)!r}; transfer={time.monotonic()-start:.1f}s', flush=True)
        if not received or received[0] != ord('K'):
            raise RuntimeError('No successful DDR/CRC acknowledgement; reset board before retrying')
        # A read can contain the ACK followed by the first boot records.
        # Feed those bytes through the same logging/prompt path as later reads.
        pending_console = bytes(received[1:])
        port.baudrate = args.console_baud
    else:
        print('Attaching to running Linux console', flush=True)
        port.write(b'\n')
    transcript = bytearray()
    command_sent = verified = False
    reboot = RebootDetector()
    deadline = time.monotonic()+args.timeout
    with args.log.open('ab' if args.append_log else 'wb') as log:
        while time.monotonic() < deadline or (verified and args.keep_open):
            chunk = pending_console or port.read(max(1, port.in_waiting))
            pending_console = b''
            if not chunk:
                continue
            if not verified:
                transcript.extend(chunk)
            log.write(chunk)
            log.flush()
            print(chunk.decode('utf-8', errors='replace'), end='', flush=True)
            restarting = reboot.feed(chunk)
            if not verified and not command_sent and b' # ' in transcript:
                command_sent = True
                for value in b'echo FPGA_BOOT_OK; uname -a\n':
                    port.write(bytes([value]))
                    time.sleep(args.input_delay)
            if not verified:
                normalized = bytes(transcript).replace(b'\r', b'')
                if command_sent and b'\nFPGA_BOOT_OK\n' in normalized and re.search(rb'\nLinux [^\n]+ riscv32 GNU/Linux\n', normalized):
                    print('\nPASS: physical FPGA reached Linux shell and executed UART command', flush=True)
                    verified = True
                    if not args.keep_open:
                        return 'passed'
            # Verification and a reboot request may arrive in the same read.
            if args.auto_reboot and verified and restarting:
                print('\nLinux requested reboot; waiting for the FPGA loader and reloading the saved image.', flush=True)
                return 'reboot'
    raise RuntimeError(f'Linux shell/command timeout; inspect {args.log}')


def main():
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('port', help='board UART, e.g. /dev/ttyUSB1')
    parser.add_argument('image', type=Path, nargs='?', default=here / 'build/linux-image/fw_payload.bin')
    parser.add_argument('--baud', type=int, default=1000000)
    parser.add_argument('--console-baud', type=int, default=115200)
    parser.add_argument('--console-only', action='store_true', help='attach to an already booted board without an initial upload')
    parser.add_argument('--keep-open', action='store_true', help='keep capturing UART after a successful test')
    parser.add_argument('--auto-reboot', action='store_true', help='reload the saved image after a verified Linux reboot request; requires a software-reset bitstream; implies --keep-open')
    parser.add_argument('--program-bitstream', type=Path, help='program this bitstream once before opening the UART')
    parser.add_argument('--timeout', type=float, default=600, help='seconds to wait for a shell after each upload')
    parser.add_argument('--input-delay', type=float, default=0.1, help='seconds between console input bytes for the uncached CPU')
    parser.add_argument('--log', type=Path, default=here / 'build/hardware-uart.log')
    parser.add_argument('--append-log', action='store_true', help='append a new boot so attached console clients keep their position')
    args = parser.parse_args()
    if args.console_only and args.program_bitstream:
        parser.error('--console-only cannot be combined with --program-bitstream')
    if args.timeout <= 0 or args.input_delay < 0:
        parser.error('timeout must be positive and input delay nonnegative')
    import serial

    # Freeze the payload for all reloads in this reader session. A host rebuild
    # must not silently change the next reboot's kernel/DTB/clock configuration.
    packet = frame(args.image.read_bytes()) if args.auto_reboot or not args.console_only else None
    args.log.parent.mkdir(parents=True, exist_ok=True)
    if args.auto_reboot:
        args.keep_open = True
    if args.program_bitstream:
        program_bitstream(args.program_bitstream, Path(str(args.log)+'.program.log'))
    initial = None if args.console_only else packet
    initial_baud = args.console_baud if args.console_only else args.baud
    with serial.Serial(args.port, initial_baud, timeout=0.1, write_timeout=10, exclusive=True) as port:
        while True:
            event = capture_once(args, initial, port)
            if event != 'reboot':
                return
            # Keep this same FD, flock, and modem state. The FPGA reset register
            # rearms the loader; only the UART speed and payload transfer change.
            initial = packet
            args.append_log = True


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'Board test failed: {error}', file=sys.stderr)
        sys.exit(1)
