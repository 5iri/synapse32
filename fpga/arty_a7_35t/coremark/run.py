#!/usr/bin/env python3
"""Run and validate CoreMark on Linux through the retained FPGA UART."""
import argparse
import json
import re
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'triangulator'))
from uart_link import LogLines, UartWriter


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('port')
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--iterations', type=int, default=1)
    parser.add_argument('--cpu-mhz', type=float, default=50)
    parser.add_argument('--optimizations', nargs='+', choices=['o3', 'o2'], default=['o3', 'o2'])
    parser.add_argument('--profiler', help='Absolute path to the FPGA Linux counter wrapper')
    parser.add_argument('--binary-prefix', default='/tmp/coremark',
                        help='Binary path before -o3/-o2 (default: /tmp/coremark)')
    args = parser.parse_args()
    if not 1 <= args.repeats <= 10:
        parser.error('repeats must be 1..10')
    if not 0 <= args.iterations <= 1000000:
        parser.error('iterations must be 0..1000000 (zero enables upstream calibration)')
    if not 0 < args.cpu_mhz <= 1000:
        parser.error('cpu-mhz must be the actual positive hardware clock')
    if args.profiler and not re.fullmatch(r'/[A-Za-z0-9_./-]+', args.profiler):
        parser.error('profiler must be an absolute path without shell characters')
    if not re.fullmatch(r'/[A-Za-z0-9_./-]+', args.binary_prefix):
        parser.error('binary prefix must be an absolute path without shell characters')
    writer, lines = UartWriter(args.port), LogLines(args.log)
    results = []
    try:
        writer.send(b'\necho S32_COREMARK_READY\n', 0.01)
        lines.wait(lambda line: line == 'S32_COREMARK_READY')
        cases = [(opt, 'performance', repeat) for opt in args.optimizations
                 for repeat in range(args.repeats)]
        cases += [(opt, 'validation', 0) for opt in args.optimizations]
        for index, (opt, mode, repeat) in enumerate(cases):
            seeds = '0 0 0x66' if mode == 'performance' else '0x3415 0x3415 0x66'
            marker = f'S32_COREMARK_DONE_{index}'
            # Both seed sets use all algorithms and the standard 2000-byte data.
            prefix = f'{args.profiler} ' if args.profiler else ''
            binary = f'{args.binary_prefix}-{opt}'
            command = f'{prefix}{binary} {seeds} {args.iterations} 7 1; echo {marker}:$?\n'
            writer.send(command.encode(), 0.01)
            captured = []
            deadline = time.monotonic() + 600
            completed = False
            while time.monotonic() < deadline and not completed:
                for line in lines.read():
                    captured.append(line)
                    print(line, flush=True)
                    if line.startswith(marker + ':'):
                        if line != marker + ':0':
                            raise RuntimeError(f'CoreMark process failed: {line}')
                        completed = True
                time.sleep(0.02)
            output = '\n'.join(captured)
            if not completed:
                raise RuntimeError('CoreMark timed out; inspect the retained UART log')
            if 'Correct operation validated.' not in output or 'ERROR!' in output:
                raise RuntimeError('CoreMark did not validate')
            def field(label):
                match = re.search(r'^' + re.escape(label) + r'\s*:\s*([0-9.]+)', output, re.M)
                if not match:
                    raise RuntimeError(f'Missing CoreMark field {label}')
                return float(match.group(1))
            seconds, score = field('Total time (secs)'), field('Iterations/Sec')
            if seconds < 10:
                raise RuntimeError('CoreMark run shorter than ten seconds')
            expected_crc = '0xe9f5' if mode == 'performance' else '0x18f2'
            if not re.search(r'^seedcrc\s*:\s*' + expected_crc, output, re.M):
                raise RuntimeError('Unexpected CoreMark data size or seeds')
            result = {'optimization': opt, 'mode': mode, 'repeat': repeat, 'binary': binary,
                      'seconds': seconds, 'iterations_per_second': score,
                      'iterations': int(field('Iterations')),
                      'cpu_mhz': args.cpu_mhz,
                      'coremark_per_mhz': score / args.cpu_mhz, 'validated': True, 'output': output}
            if args.profiler:
                result['profiling'] = {name: int(value, 16) for name, value in
                                       re.findall(r'^S32_PERF (\w+): (0x[0-9a-fA-F]+)$', output, re.M)}
                if len(result['profiling']) != 16:
                    raise RuntimeError('Missing hardware profiling counters')
                result['profiling_scope'] = 'whole CPU during command, including kernel/background activity'
            results.append(result)
            args.output.write_text(json.dumps(results, indent=2) + '\n')
            print('VALIDATED ' + json.dumps({k: v for k, v in result.items() if k != 'output'}), flush=True)
        for opt in args.optimizations:
            scores = [r['iterations_per_second'] for r in results
                      if r['optimization'] == opt and r['mode'] == 'performance']
            print(f'{opt}: median {statistics.median(scores):.6f} CoreMark, '
                  f'{statistics.median(scores)/args.cpu_mhz:.6f} CoreMark/MHz', flush=True)
    except BaseException:
        # A failed or timed-out run must not leave its foreground workload
        # occupying the console after the host runner exits.
        writer.send(b'\x03')
        raise
    finally:
        writer.close()
        lines.close()


if __name__ == '__main__':
    main()
