#!/usr/bin/env python3
"""Measure a fixed mesh sequence through an already retained FPGA UART."""
import argparse
import json
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'triangulator'))
from protocol import mesh_record
from uart_link import LogLines, UartWriter


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('port')
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    writer = UartWriter(args.port)
    lines = LogLines(args.log)
    results = []
    try:
        writer.send(b'\x03\necho S32_BENCH_READY\n', 0.01)
        lines.wait(lambda line: line == 'S32_BENCH_READY')
        for points, frames in [(16, 30), (32, 20), (64, 10)]:
            command = f'/bin/triangulator --points {points} --frames {frames}\n'
            writer.send(command.encode(), 0.01)
            records, arrivals = [], []
            deadline = time.monotonic() + 300
            done = False
            while not done and time.monotonic() < deadline:
                for line in lines.read():
                    if line == 'S32DONE':
                        done = True
                    record = mesh_record(line)
                    if record is not None:
                        assert len(record['points']) == points
                        assert record['frame'] == len(records)
                        records.append(record)
                        arrivals.append(time.monotonic())
                time.sleep(0.01)
            if not done or len(records) != frames:
                raise RuntimeError(f'Incomplete {points}-point run: {len(records)}/{frames}')
            times = [record['compute_us'] / 1000 for record in records]
            result = {'points': points, 'frames': frames,
                      'median_ms': statistics.median(times), 'min_ms': min(times),
                      'max_ms': max(times),
                      'received_fps': (frames - 1) / (arrivals[-1] - arrivals[0]),
                      'records': records}
            results.append(result)
            args.output.write_text(json.dumps(results, indent=2) + '\n')
            print(json.dumps({key: value for key, value in result.items() if key != 'records'}), flush=True)
    finally:
        writer.close()
        lines.close()


if __name__ == '__main__':
    main()
