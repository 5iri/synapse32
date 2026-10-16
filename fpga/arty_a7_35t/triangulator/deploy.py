#!/usr/bin/env python3
"""Copy the demo to running FPGA Linux without resetting or reconfiguring UART."""
import argparse
import base64
import hashlib
import re
from pathlib import Path

from uart_link import LogLines, UartWriter


def main():
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--binary", type=Path, default=here.parent / "build/triangulator/triangulator")
    parser.add_argument("--destination", default="/tmp/triangulator")
    parser.add_argument("--byte-delay", type=float, default=0.005)
    parser.add_argument("--chunk-bytes", type=int, default=192,
                        help="bytes per acknowledged base64 command (1..65536; default: 192)")
    args = parser.parse_args()
    if not re.fullmatch(r"/[A-Za-z0-9_./-]+", args.destination):
        parser.error("destination must be an absolute path without shell characters")
    if args.byte_delay < 0:
        parser.error("byte delay must be nonnegative")
    if not 1 <= args.chunk_bytes <= 65536:
        parser.error("chunk bytes must be in 1..65536")
    binary = args.binary.read_bytes()
    digest = hashlib.sha256(binary).hexdigest()
    writer = UartWriter(args.port)
    lines = LogLines(args.log)
    try:
        writer.send(b"/bin/busybox stty -echo; read S32_UPLOAD_LOGLEVEL S32_UPLOAD_UNUSED < /proc/sys/kernel/printk; "
                    b"/bin/busybox dmesg -n 5; echo S32_UPLOAD_READY\n")
        lines.wait(lambda line: line == "S32_UPLOAD_READY")
        writer.send(f": > {args.destination}; echo S32_UPLOAD_EMPTY\n".encode(), 0.03)
        lines.wait(lambda line: line == "S32_UPLOAD_EMPTY")
        for index, offset in enumerate(range(0, len(binary), args.chunk_bytes)):
            encoded = base64.b64encode(binary[offset:offset + args.chunk_bytes]).decode("ascii")
            # Keep each canonical UART input line short even with larger chunks.
            encoded = "\n".join(encoded[start:start + 256] for start in range(0, len(encoded), 256))
            marker = f"S32_UPLOAD_ACK_{index}"
            command = (f"/bin/busybox base64 -d >> {args.destination} <<'S32_EOF' && echo {marker}\n"
                       f"{encoded}\nS32_EOF\n")
            writer.send(command.encode(), args.byte_delay)
            lines.wait(lambda line: line == marker)
            print(f"Uploaded {min(offset + args.chunk_bytes, len(binary))}/{len(binary)} bytes", flush=True)
        writer.send(f"/bin/busybox sha256sum {args.destination}\n".encode(), 0.03)
        result = lines.wait(lambda line: re.match(r"^[0-9a-f]{64}  ", line) is not None)
        if result.split()[0] != digest:
            raise RuntimeError(f"Uploaded binary checksum differs: {result}")
        writer.send(f"/bin/busybox chmod 755 {args.destination}; echo S32_UPLOAD_OK\n".encode(), 0.03)
        lines.wait(lambda line: line == "S32_UPLOAD_OK")
        print(f"Verified {args.destination}: SHA256 {digest}", flush=True)
    finally:
        # Ctrl+C also escapes an incomplete here-document following an error.
        writer.send(b"\x03")
        writer.send(b'if [ -n "${S32_UPLOAD_LOGLEVEL:-}" ]; then /bin/busybox dmesg -n "$S32_UPLOAD_LOGLEVEL"; fi; '
                    b'unset S32_UPLOAD_LOGLEVEL S32_UPLOAD_UNUSED; /bin/busybox stty echo\n')
        writer.close()
        lines.close()


if __name__ == "__main__":
    main()
