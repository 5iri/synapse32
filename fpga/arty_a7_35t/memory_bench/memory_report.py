#!/usr/bin/env python3
"""Validate complete memory benchmark captures and summarize repeated cases."""
import argparse
import json
import statistics
from pathlib import Path


PREFIX = 'S32_MEMORY_BENCH '
DONE = 'S32_MEMORY_BENCH_DONE:0'
CASES = ('register_baseline', 'dependent_loads', 'independent_loads',
         'stores_same_word', 'stores_adjacent_words', 'stores_streaming_hot',
         'stores_sparse', 'loads_streaming_cold')


def parse_report(text, repeats, expected_cases=CASES):
    runs, current = [], []
    for line in text.splitlines():
        if 'S32_MEMORY_BENCH_TRAP' in line or line.startswith('ERROR'):
            raise ValueError(f'Firmware failed: {line}')
        if line.startswith(PREFIX):
            record = json.loads(line[len(PREFIX):])
            if record.get('validated') is not True:
                raise ValueError(f'Unvalidated case: {record}')
            if not isinstance(record.get('case'), str) or not record['case']:
                raise ValueError('Missing case name')
            for field in ('cycles', 'instructions', 'operations'):
                if type(record.get(field)) is not int or record[field] <= 0:
                    raise ValueError(f'Invalid {field} in {record["case"]}')
            if any(r['case'] == record['case'] for r in current):
                raise ValueError(f'Duplicate case {record["case"]}')
            current.append(record)
        if line.startswith('S32_MEMORY_BENCH_DONE:'):
            if line != DONE or not current:
                raise ValueError('Missing cases or failed completion')
            runs.append(current)
            current = []
    if current or len(runs) != repeats:
        raise ValueError(f'Incomplete capture: {len(runs)}/{repeats} complete runs')
    names = [r['case'] for r in runs[0]]
    if list(expected_cases) != names:
        raise ValueError(f'Missing or reordered cases: {names}')
    if any([r['case'] for r in run] != names for run in runs):
        raise ValueError('Case sequence differs across runs')
    summary = []
    for i, name in enumerate(names):
        samples = [run[i] for run in runs]
        if len({r['operations'] for r in samples}) != 1:
            raise ValueError(f'Operation count changed in {name}')
        summary.append({
            'case': name, 'operations': samples[0]['operations'],
            'median_cycles': statistics.median(r['cycles'] for r in samples),
            'median_cycles_per_operation': statistics.median(r['cycles'] / r['operations'] for r in samples),
            'median_cpi': statistics.median(r['cycles'] / r['instructions'] for r in samples),
            'samples': samples,
        })
    return {'repeats': repeats, 'summary': summary, 'runs': runs}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--repeats', type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error('repeats must be positive')
    report = parse_report(args.log.read_text(), args.repeats)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    for record in report['summary']:
        print(f"PASS {record['case']}: {record['median_cycles_per_operation']:.6f} cycles/op")


if __name__ == '__main__':
    main()
