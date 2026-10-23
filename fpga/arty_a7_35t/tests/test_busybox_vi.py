#!/usr/bin/env python3
"""Exercise a static RV32 BusyBox vi under QEMU using a real Unix PTY.

No target board, external terminal emulator, or third-party Python module is
needed. Exit status, exact saved bytes, and a reopen/change/undo cycle are checked.
"""
import argparse
import errno
import fcntl
import os
from pathlib import Path
import pty
import resource
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time


class ViSession:
    def __init__(self, qemu, busybox, path, timeout):
        self.timeout = timeout
        self.transcript = bytearray()
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))

        def controlling_terminal():
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        try:
            self.process = subprocess.Popen(
                [str(qemu), str(busybox), 'vi', str(path)],
                stdin=slave, stdout=slave, stderr=slave,
                env={**os.environ, 'TERM': 'vt100', 'LC_ALL': 'C'},
                preexec_fn=controlling_terminal, cwd=path.parent,
            )
        except BaseException:
            os.close(self.master)
            raise
        finally:
            os.close(slave)

    def read(self, wait=0.05):
        if not select.select([self.master], [], [], wait)[0]:
            return False
        try:
            data = os.read(self.master, 65536)
        except OSError as error:
            if error.errno == errno.EIO:  # Linux PTY EOF after child exit.
                return False
            raise
        if not data:
            return False
        old_length = len(self.transcript)
        self.transcript.extend(data)
        if len(self.transcript) > 1024 * 1024:
            raise RuntimeError('vi produced more than 1 MiB of terminal output')
        # FEATURE_VI_ASK_TERMINAL probes terminal size by requesting the cursor
        # position after moving to the bottom right. A PTY is not an emulator;
        # answer that one query using the configured 24x80 terminal dimensions.
        start = max(0, old_length - 3)
        while True:
            index = self.transcript.find(b'\x1b[6n', start)
            if index < 0:
                break
            if index + 4 > old_length:
                os.write(self.master, b'\x1b[24;80R')
            start = index + 4
        return True

    def startup(self):
        deadline = time.monotonic() + self.timeout
        last_output = time.monotonic()
        while time.monotonic() < deadline:
            if self.read():
                last_output = time.monotonic()
            status = self.process.poll()
            if status is not None:
                self.read(0)
                raise RuntimeError(f'vi exited during startup (status {status})')
            if self.transcript and time.monotonic() - last_output >= 0.15:
                return
        raise RuntimeError('vi startup did not reach an idle terminal before deadline')

    def send(self, data):
        if self.process.poll() is not None:
            raise RuntimeError(f'vi exited before input (status {self.process.returncode})')
        view = memoryview(data)
        while view:
            view = view[os.write(self.master, view):]
        # Drain redraws and let escape terminate insert mode before a colon
        # command. This is bounded even if vi stops responding.
        until = time.monotonic() + 0.08
        while time.monotonic() < until:
            self.read(min(0.02, max(0, until - time.monotonic())))

    def finish(self):
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            self.read()
            status = self.process.poll()
            if status is not None:
                while self.read(0):
                    pass
                if status != 0:
                    raise RuntimeError(f'vi exited with status {status}')
                return
        raise RuntimeError('vi failed to write/quit before deadline')

    def close(self):
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=1)
        os.close(self.master)


def run(qemu, busybox, timeout, transcripts):
    with tempfile.TemporaryDirectory(prefix='synapse32-vi-') as directory:
        path = Path(directory) / 'edit.txt'
        cases = [
            ('insert-write-quit', [b'ifirst line from vi\nsecond line', b'\x1b', b':wq\r'],
             b'first line from vi\nsecond line\n'),
            # Append a temporary change, undo that insertion, then change the
            # first word. The final bytes verify both undo and reopening.
            ('reopen-modify-undo-write', [b'G$A temporary', b'\x1b', b'u',
                                          b'1G0cwupdated', b'\x1b', b':wq\r'],
             b'updated line from vi\nsecond line\n'),
        ]
        for name, commands, expected in cases:
            session = ViSession(qemu, busybox, path, timeout)
            try:
                session.startup()
                for command in commands:
                    session.send(command)
                session.finish()
                actual = path.read_bytes()
                if actual != expected:
                    raise RuntimeError(f'{name}: saved bytes {actual!r}, expected {expected!r}')
                print(f'PASS: {name}; exact {len(actual)} file bytes', flush=True)
            finally:
                session.close()
                transcripts.append((name, bytes(session.transcript)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--qemu', type=Path, required=True)
    parser.add_argument('--busybox', type=Path, required=True)
    parser.add_argument('--timeout', type=float, default=10,
                        help='Maximum seconds per startup/exit phase (default: 10)')
    parser.add_argument('--transcript', type=Path, help='Write raw PTY output, including failures')
    args = parser.parse_args()
    if not 0 < args.timeout <= 60:
        parser.error('--timeout must be greater than zero and at most 60')
    for name in ('qemu', 'busybox'):
        path = getattr(args, name).resolve()
        if not path.is_file() or not os.access(path, os.X_OK):
            parser.error(f'--{name} must name an executable file: {path}')
        setattr(args, name, path)
    transcripts = []
    try:
        run(args.qemu, args.busybox, args.timeout, transcripts)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        if transcripts:
            print(f'PTY tail: {transcripts[-1][1][-400:]!r}', file=sys.stderr)
        return 1
    finally:
        if args.transcript:
            args.transcript.parent.mkdir(parents=True, exist_ok=True)
            with args.transcript.open('wb') as output:
                for name, data in transcripts:
                    output.write(f'\n=== {name} ===\n'.encode())
                    output.write(data)
    print('PASS: BusyBox vi startup, insert, save, reopen, modify, undo and quit')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
