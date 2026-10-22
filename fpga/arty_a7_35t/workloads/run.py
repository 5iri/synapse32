#!/usr/bin/env python3
"""Run validated Linux workloads through an already retained FPGA UART."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import time
from datetime import datetime, timezone

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'triangulator'))
from uart_link import LogLines, UartWriter
from report import parse_run, summarize


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('port')
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, default=Path(__file__).resolve().parents[1] / 'build/workloads/manifest.json')
    parser.add_argument('--binary', default='/bin/workloads')
    parser.add_argument('--cpu-mhz', type=float, required=True, help='actual measured/configured hardware clock')
    parser.add_argument('--kernel-hz', type=int, required=True)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--iterations', type=int, default=3)
    parser.add_argument('--timeout', type=float, default=900)
    args = parser.parse_args()
    if not re.fullmatch(r'/[A-Za-z0-9_./-]+', args.binary):
        parser.error('binary must be an absolute path without shell characters')
    if not 1 <= args.repeats <= 20 or not 1 <= args.iterations <= 100:
        parser.error('repeats must be 1..20 and iterations 1..100')
    if not 0 < args.cpu_mhz <= 1000 or not 1 <= args.kernel_hz <= 10000 or not 0 < args.timeout <= 86400:
        parser.error('invalid clock, kernel tick rate or timeout')
    manifest_bytes = args.manifest.read_bytes()
    manifest = json.loads(manifest_bytes)
    if manifest.get('target') != 'riscv32-linux-ilp32':
        parser.error('manifest must describe an RV32 Linux build')
    report = {'schema': 1, 'started_utc': datetime.now(timezone.utc).isoformat(),
              'cpu_mhz': args.cpu_mhz, 'kernel_hz': args.kernel_hz,
              'clock_configuration_source': 'host command-line; match the programmed bitstream and DTB',
              'binary': args.binary, 'manifest': manifest,
              'manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(),
              'retained_uart_log': str(args.log.resolve()), 'runs': [], 'completed': False}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    writer, lines = UartWriter(args.port), LogLines(args.log)
    try:
        writer.send(b'\necho S32_WORKLOAD_READY\n', 0.01)
        lines.wait(lambda line: line == 'S32_WORKLOAD_READY')
        writer.send(f'/bin/busybox sha256sum {args.binary}\n'.encode(), 0.01)
        identity = lines.wait(lambda line: re.fullmatch(r'[0-9a-f]{64}  ' + re.escape(args.binary), line) is not None)
        if identity.split()[0] != manifest['binary_sha256']:
            raise RuntimeError('Board executable SHA256 differs from the supplied manifest')
        for repeat in range(args.repeats):
            marker = f'S32_WORKLOAD_EXIT_{repeat}'
            writer.send(f'{args.binary} {args.iterations}; echo {marker}:$?\n'.encode(), 0.01)
            captured, completed = [], False
            deadline = time.monotonic() + args.timeout
            while time.monotonic() < deadline and not completed:
                for line in lines.read():
                    captured.append(line)
                    print(line, flush=True)
                    if line.startswith(marker + ':'):
                        if line != marker + ':0':
                            raise RuntimeError(f'Workload process failed: {line}')
                        completed = True
                time.sleep(0.02)
            if not completed:
                raise RuntimeError('Workload timed out; inspect the retained UART log')
            result = parse_run(captured, manifest)
            if result['configuration']['iterations'] != args.iterations:
                raise RuntimeError('Workload iteration count differs from requested count')
            result.update({'repeat': repeat, 'raw_output': captured})
            report['runs'].append(result)
            report['summary'] = summarize(report['runs'])
            report['completed'] = len(report['runs']) == args.repeats
            args.output.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report['summary'], indent=2), flush=True)
    except BaseException as error:
        report['completed'] = False
        report['error'] = str(error)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        writer.send(b'\x03')
        raise
    finally:
        writer.close()
        lines.close()


if __name__ == '__main__':
    main()
