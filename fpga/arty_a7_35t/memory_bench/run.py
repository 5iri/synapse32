#!/usr/bin/env python3
"""Load and measure memory microbenchmarks on the physical FPGA UART."""
import argparse
import hashlib
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from upload import frame
from memory_report import parse_report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('port')
    parser.add_argument('--image', type=Path, required=True)
    parser.add_argument('--baud', type=int, default=2000000)
    parser.add_argument('--cpu-hz', type=int, required=True)
    parser.add_argument('--repeats', type=int, default=5)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.repeats <= 20 or args.cpu_hz < 1000:
        parser.error('repeats must be 1..20 and cpu-hz at least 1000')
    import serial
    capture, completed, clock_verified = [], 0, False
    payload = args.image.read_bytes()
    with serial.Serial(args.port, args.baud, timeout=0.1, write_timeout=15, exclusive=True) as port, args.log.open('w') as log:
        time.sleep(0.2)
        port.reset_input_buffer()
        packet = frame(payload)
        if port.write(packet) != len(packet):
            raise RuntimeError('Short payload upload')
        port.flush()
        if port.read(1) != b'K':
            raise RuntimeError('Loader did not accept benchmark image')
        port.baudrate = 115200
        pending = bytearray()
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            chunk = port.read(4096)
            if not chunk:
                continue
            pending.extend(chunk)
            while b'\n' in pending:
                raw, _, remainder = pending.partition(b'\n')
                pending[:] = remainder
                line = raw.decode('utf-8', errors='replace').rstrip('\r')
                capture.append(line)
                log.write(line + '\n'); log.flush()
                print(line, flush=True)
                if line.startswith('S32_MEMORY_BENCH_CPU_HZ:'):
                    if int(line.split(':', 1)[1]) != args.cpu_hz:
                        raise RuntimeError('Firmware clock does not match --cpu-hz')
                    clock_verified = True
                if 'S32_MEMORY_BENCH_TRAP' in line or line.startswith('ERROR'):
                    raise RuntimeError(line)
                if line == 'S32_MEMORY_BENCH_READY':
                    if not clock_verified:
                        raise RuntimeError('Missing firmware clock metadata')
                    if completed < args.repeats:
                        port.write(b'r\n'); port.flush()
                if line.startswith('S32_MEMORY_BENCH_DONE:'):
                    if line != 'S32_MEMORY_BENCH_DONE:0':
                        raise RuntimeError(line)
                    completed += 1
                    if completed == args.repeats:
                        report = parse_report('\n'.join(capture), args.repeats)
                        report['metadata'] = {
                            'cpu_hz': args.cpu_hz, 'loader_baud': args.baud,
                            'payload_sha256': hashlib.sha256(payload).hexdigest(),
                            'environment': 'bare metal M-mode, interrupts disabled',
                        }
                        args.output.write_text(json.dumps(report, indent=2) + '\n')
                        return
        raise TimeoutError(f'Only {completed}/{args.repeats} benchmark runs completed')


if __name__ == '__main__':
    main()
