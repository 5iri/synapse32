#!/usr/bin/env python3
"""Upload bare-metal CoreMark and validate repeated physical UART reports."""
import argparse
import hashlib
import json
import math
import re
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from upload import frame


def main():
    here = Path(__file__).resolve().parent
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('port')
    p.add_argument('--image', type=Path, default=here.parent / 'build/coremark-baremetal/coremark.bin')
    p.add_argument('--baud', type=int, default=2000000)
    p.add_argument('--no-upload', action='store_true', help='capture initialized BRAM firmware; start before programming')
    p.add_argument('--cpu-mhz', type=float, default=62.5)
    p.add_argument('--iterations', type=int, default=2)
    p.add_argument('--repeats', type=int, default=3)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--log', type=Path, required=True)
    args = p.parse_args()
    if not 1 <= args.iterations <= 1000000 or not 1 <= args.repeats <= 10:
        p.error('iterations must be 1..1000000; repeats must be 1..10')
    import serial
    reports, pilots = [], []
    metadata = {'cpu_mhz': args.cpu_mhz, 'environment': 'bare-metal M-mode, satp=0, interrupts disabled',
                'payload_sha256': hashlib.sha256(args.image.read_bytes()).hexdigest()}
    def save():
        args.output.write_text(json.dumps({'metadata': metadata, 'pilots': pilots, 'results': reports}, indent=2) + '\n')
    with serial.Serial(args.port, 115200 if args.no_upload else args.baud, timeout=0.1, write_timeout=15, exclusive=True) as port, args.log.open('w') as log:
        time.sleep(0.2)
        port.reset_input_buffer()
        if not args.no_upload:
            packet = frame(args.image.read_bytes())
            if port.write(packet) != len(packet):
                raise RuntimeError('short payload write')
            port.flush()
            reply = port.read(1)
            if reply != b'K':
                raise RuntimeError(f'loader rejected bare-metal image: {reply!r}')
            port.baudrate = 115200
            print(f'Bare-metal payload accepted: {len(packet)-12} bytes', flush=True)
        else:
            print('Waiting for initialized BRAM firmware at 115200 baud', flush=True)

        def line_until(deadline):
            data = bytearray()
            while time.monotonic() < deadline:
                chunk = port.read(1)
                if not chunk:
                    continue
                data += chunk
                if chunk == b'\n':
                    line = data.decode('utf-8', errors='replace').strip('\r\n')
                    log.write(line + '\n'); log.flush()
                    print(line, flush=True)
                    if 'S32_BAREMETAL_TRAP' in line:
                        raise RuntimeError(line)
                    return line
            raise TimeoutError('bare-metal UART response timed out')

        deadline = time.monotonic() + 60
        timer_start = None
        while True:
            line = line_until(deadline)
            if line.startswith('S32_BAREMETAL_CPU_HZ:'):
                hz = int(line.split(':')[1])
                if hz != round(args.cpu_mhz * 1000000):
                    raise RuntimeError('CPU clock argument does not match bare-metal payload')
            if line == 'S32_TIMER_START':
                timer_start = time.monotonic()
            if line == 'S32_TIMER_END':
                if timer_start is None:
                    raise RuntimeError('missing timer self-test start')
                elapsed = time.monotonic() - timer_start
                if not 1.5 <= elapsed <= 3:
                    raise RuntimeError(f'two-second timer self-test took {elapsed:.3f}s on host')
                metadata['timer_selftest_host_seconds'] = elapsed
            if line.startswith('Timer selftest cycles:'):
                ticks = int(line.split(':')[1], 16)
                if abs(ticks / (args.cpu_mhz * 1000000) - 2) > 0.02:
                    raise RuntimeError('mtime and cycle counter disagree')
                metadata['timer_selftest_cycles'] = ticks
            if line == 'S32_BAREMETAL_READY':
                break
        if 'timer_selftest_cycles' not in metadata:
            raise RuntimeError('missing timer self-test')

        iterations = args.iterations
        for index, mode in enumerate(['performance'] * args.repeats + ['validation']):
            for attempt in range(3):
                command = f'{"p" if mode == "performance" else "v"} {iterations}\n'
                port.write(command.encode()); port.flush()
                captured = []
                deadline = time.monotonic() + 600
                while True:
                    line = line_until(deadline)
                    captured.append(line)
                    if line.startswith('S32_BAREMETAL_DONE:'):
                        if line != 'S32_BAREMETAL_DONE:0':
                            raise RuntimeError('CoreMark returned an error')
                        break
                output = '\n'.join(captured)
                def field(name):
                    match = re.search(r'^' + re.escape(name) + r'\s*:\s*([0-9.]+)', output, re.M)
                    if not match:
                        raise RuntimeError(f'missing {name}')
                    return float(match[1])
                seconds = field('Total time (secs)')
                error_lines = [line for line in captured if 'ERROR!' in line]
                short_error = 'ERROR! Must execute for at least 10 secs for a valid result!'
                if seconds < 10 and error_lines == [short_error]:
                    pilots.append({'mode': mode, 'seconds': seconds, 'iterations': iterations, 'output': output})
                    iterations = min(1000000, max(iterations + 1, math.ceil(iterations * 15 / max(seconds, 0.001))))
                    save()
                    while line_until(deadline) != 'S32_BAREMETAL_READY':
                        pass
                    continue
                if seconds < 10 or error_lines or 'Correct operation validated.' not in output:
                    raise RuntimeError('CoreMark run failed validation')
                crc = '0xe9f5' if mode == 'performance' else '0x18f2'
                if not re.search(r'^seedcrc\s*:\s*' + crc, output, re.M):
                    raise RuntimeError('unexpected benchmark size or seeds')
                def counter(label):
                    match = re.search(r'^' + re.escape(label) + r': (0x[0-9a-f]+)', output, re.M)
                    if not match:
                        raise RuntimeError(f'missing {label}')
                    return int(match[1], 16)
                cycles = counter('Timed CPU cycles')
                instructions = counter('Timed retired instructions')
                result = {'mode': mode, 'repeat': index, 'iterations': int(field('Iterations')),
                          'seconds': seconds, 'iterations_per_second': field('Iterations/Sec'),
                          'cpu_mhz': args.cpu_mhz, 'cycles': cycles, 'retired_instructions': instructions,
                          'cpi': cycles / instructions, 'validated': True, 'output': output}
                profiling = {name: int(value, 16) for name, value in
                             re.findall(r'^S32_PERF ([a-z_]+): (0x[0-9a-fA-F]+)$', output, re.M)}
                if profiling:
                    result['profiling'] = profiling
                if abs(cycles / (args.cpu_mhz * 1000000) - seconds) > 0.05:
                    raise RuntimeError('reported time and timed cycle counter disagree')
                reports.append(result); save()
                print('VALIDATED ' + json.dumps({k: v for k, v in result.items() if k != 'output'}), flush=True)
                while line_until(deadline) != 'S32_BAREMETAL_READY':
                    pass
                break
            else:
                raise RuntimeError('could not obtain a ten-second benchmark run')
        score = statistics.median(r['iterations_per_second'] for r in reports if r['mode'] == 'performance')
        print(f'Bare-metal median: {score:.6f} CoreMark; {score/args.cpu_mhz:.6f} CoreMark/MHz', flush=True)


if __name__ == '__main__':
    main()
