#!/usr/bin/env python3
"""Upload Linux, capture the physical UART, and verify a shell command."""
import argparse
import sys
import time
from pathlib import Path

from upload import frame


def main():
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", help="board UART, e.g. /dev/ttyUSB1")
    parser.add_argument("image", type=Path, nargs="?", default=here / "build/linux-image/fw_payload.bin")
    parser.add_argument("--baud", type=int, default=1000000)
    parser.add_argument("--console-baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=600, help="seconds to wait for a shell after upload")
    parser.add_argument("--log", type=Path, default=here / "build/hardware-uart.log")
    args = parser.parse_args()
    import serial

    packet = frame(args.image.read_bytes())
    args.log.parent.mkdir(parents=True, exist_ok=True)
    with serial.Serial(args.port, args.baud, timeout=0.1, write_timeout=10, exclusive=True) as port:
        time.sleep(1)
        port.reset_input_buffer()
        start = last = time.monotonic()
        print(f"Uploading {len(packet)-12:,} bytes at {args.baud} baud", flush=True)
        received = bytearray()
        for offset in range(0, len(packet), 16384):
            block = packet[offset:offset+16384]
            if port.write(block) != len(block):
                raise RuntimeError("Short serial write")
            if port.in_waiting:
                received.extend(port.read(port.in_waiting))
                if received[0] == ord("E"):
                    raise RuntimeError(f"Loader rejected transfer after {offset+len(block):,} bytes")
            now = time.monotonic()
            if now-last >= 5:
                print(f"{min(offset+len(block),len(packet))*100/len(packet):.1f}% elapsed={now-start:.1f}s", flush=True)
                last = now
        port.flush()
        deadline = time.monotonic()+10
        while not received and time.monotonic() < deadline:
            received.extend(port.read(1))
        print(f"Loader reply={bytes(received)!r}; transfer={time.monotonic()-start:.1f}s", flush=True)
        if not received or received[0] != ord("K"):
            raise RuntimeError("No successful DDR/CRC acknowledgement; reset board before retrying")
        port.baudrate = args.console_baud
        transcript = bytearray()
        command_sent = False
        deadline = time.monotonic()+args.timeout
        with args.log.open("wb") as log:
            while time.monotonic() < deadline:
                chunk = port.read(max(1, port.in_waiting))
                if not chunk:
                    continue
                transcript.extend(chunk)
                log.write(chunk)
                log.flush()
                print(chunk.decode("utf-8", errors="replace"), end="", flush=True)
                if not command_sent and b" # " in transcript:
                    command_sent = True
                    for value in b"echo FPGA_BOOT_OK; uname -a\n":
                        port.write(bytes([value]))
                        time.sleep(0.005)
                normalized = bytes(transcript).replace(b"\r", b"")
                if command_sent and b"\nFPGA_BOOT_OK\n" in normalized and b"Linux synapse32 " in normalized:
                    print("\nPASS: physical FPGA reached Linux shell and executed UART command", flush=True)
                    return
        raise RuntimeError(f"Linux shell/command timeout; inspect {args.log}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        print(f"Board test failed: {error}", file=sys.stderr)
        sys.exit(1)
