#!/usr/bin/env python3
"""Load a raw OpenSBI fw_payload.bin into the Arty's DDR, then open a console."""
import argparse
import struct
import sys
import time
import zlib
from pathlib import Path


def frame(image):
    image += bytes(-len(image) % 4)
    if not 0 < len(image) <= 64 * 1024 * 1024:
        raise ValueError("image must contain 1..64 MiB after word padding")
    return b"S32!" + struct.pack("<I", len(image)) + image + struct.pack("<I", zlib.crc32(image))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", help="Arty USB UART, e.g. /dev/ttyUSB1")
    parser.add_argument("image", type=Path, help="raw binary linked at 0x80000000")
    parser.add_argument("--baud", type=int, default=1000000, help="boot loader baud rate (default: 1000000)")
    parser.add_argument("--console-baud", type=int, default=115200, help="Linux console baud rate (default: 115200)")
    parser.add_argument("--console", action="store_true", help="open interactive console after loading")
    args = parser.parse_args()
    import serial
    packet = frame(args.image.read_bytes())
    print(f"Uploading {len(packet)-12:,} bytes; expected duration {(len(packet)*10/args.baud):.0f}s. Hold/release RESET before starting.")
    with serial.Serial(args.port, args.baud, timeout=10, write_timeout=30) as port:
        # Allow the USB UART to settle before sending the protocol magic.
        time.sleep(1)
        port.reset_input_buffer()
        start = time.monotonic()
        for offset in range(0, len(packet), 4096):
            port.write(packet[offset:offset+4096])
            print(f"\r{min(offset+4096,len(packet))*100/len(packet):5.1f}%", end="", flush=True)
        port.flush()
        ack = port.read(1)
        print()
        if ack != b"K":
            sys.exit(f"Loader returned {ack!r}; reset board and retry. E means length/CRC/DDR overrun rejected.")
        print(f"DDR image accepted in {time.monotonic()-start:.1f}s; CPU released.")
        port.baudrate = args.console_baud
        if args.console:
            from serial.tools.miniterm import Miniterm
            terminal = Miniterm(port, echo=False, eol="lf")
            terminal.exit_character = chr(0x1d)
            print("Console: Ctrl+] exits.")
            terminal.start()
            terminal.join()
            terminal.stop()
            terminal.close()


if __name__ == "__main__":
    main()
