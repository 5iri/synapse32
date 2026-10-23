#!/usr/bin/env python3
"""Interact with a UART held open by test_board.py --keep-open."""
import argparse
import os
import select
import sys
import termios
import time
import tty
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", help="same UART device as the running reader")
    parser.add_argument("--log", type=Path, required=True, help="UART log from the running reader")
    parser.add_argument("--from-start", action="store_true", help="show the captured boot before following live output")
    parser.add_argument("--input-delay", type=float, default=0.1, help="seconds between input bytes")
    args = parser.parse_args()
    if not sys.stdin.isatty():
        parser.error("run this console in an interactive terminal")
    if args.input_delay < 0:
        parser.error("--input-delay must be nonnegative")

    # A live reader must retain its handle: configuring or reopening a closed
    # USB UART can pulse the board's DTR-connected RESET pin. Check its flock
    # before opening a write-only companion handle; never change UART settings.
    locked = False
    with Path("/proc/locks").open() as locks:
        device = os.stat(args.port)
        identity = f"{os.major(device.st_dev):02x}:{os.minor(device.st_dev):02x}:{device.st_ino}"
        locked = any(len(fields := line.split()) > 5 and fields[1] == "FLOCK" and fields[5] == identity for line in locks)
    if not locked:
        parser.error("no active UART reader; start test_board.py --keep-open first")

    with args.log.open("rb") as log:
        if not args.from_start:
            log.seek(0, os.SEEK_END)
        uart_fd = os.open(args.port, os.O_WRONLY | os.O_NOCTTY | os.O_NONBLOCK)
        keyboard = sys.stdin.fileno()
        saved = termios.tcgetattr(keyboard)
        queued = bytearray(b"\n")
        next_write = 0.0
        print("Connected to FPGA Linux. Ctrl+] exits; Ctrl+C interrupts a Linux command.", flush=True)
        try:
            tty.setraw(keyboard)
            while True:
                output = log.read(65536)
                if output:
                    sys.stdout.buffer.write(output)
                    sys.stdout.buffer.flush()
                readable, _, _ = select.select([keyboard], [], [], 0.02)
                if readable:
                    data = os.read(keyboard, 4096)
                    if not data or b"\x1d" in data:
                        return
                    queued.extend(data.replace(b"\r", b"\n"))
                now = time.monotonic()
                if queued and now >= next_write:
                    os.write(uart_fd, queued[:1])
                    del queued[:1]
                    next_write = now + args.input_delay
        finally:
            termios.tcsetattr(keyboard, termios.TCSADRAIN, saved)
            os.close(uart_fd)
            print("\nConsole detached; UART reader remains running.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except OSError as error:
        print(f"Console failed: {error}", file=sys.stderr)
        sys.exit(1)
