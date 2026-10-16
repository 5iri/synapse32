#!/usr/bin/env python3
"""Validate standard 2K CoreMark console reports and export their measurements."""
import argparse
import json
import math
import re
from pathlib import Path

EXPECTED = {
    0xe9f5: ('performance', 0xe714, 0x1fd7, 0x8e3a),
    0x18f2: ('validation', 0xe3c1, 0x0747, 0x8d84),
}
SHORT_ERROR = 'ERROR! Must execute for at least 10 secs for a valid result!'


def parse_reports(text, cpu_mhz=None, skip_short=False):
    text = text.replace('\r', '')
    if 'S32_BAREMETAL_TRAP' in text:
        raise ValueError('bare-metal program trapped')
    reports = []
    blocks = re.split(r'(?=^CoreMark Size\s*:)', text, flags=re.M)[1:]
    for block in blocks:
        def field(label, pattern=r'([^\n]+)'):
            match = re.search(r'^' + re.escape(label) + r'\s*:\s*' + pattern, block, re.M)
            if not match:
                raise ValueError(f'missing {label}')
            return match[1].strip()
        seconds = float(field('Total time (secs)'))
        errors = [line.strip() for line in block.splitlines() if 'ERROR!' in line]
        if seconds < 10 and errors == [SHORT_ERROR] and skip_short:
            continue
        if not math.isfinite(seconds) or seconds < 10:
            raise ValueError('CoreMark must run for at least ten timed seconds')
        if errors or 'Correct operation validated.' not in block:
            raise ValueError('CoreMark reported a validation error')
        seed = int(field('seedcrc'), 16)
        if seed not in EXPECTED:
            raise ValueError('unexpected seeds/data size; expected the standard 2K workload')
        mode, list_crc, matrix_crc, state_crc = EXPECTED[seed]
        for label, expected in [('crclist', list_crc), ('crcmatrix', matrix_crc), ('crcstate', state_crc)]:
            if int(field('[0]' + label), 16) != expected:
                raise ValueError(f'{label} does not match EEMBC reference')
        iterations = int(field('Iterations'))
        score = float(field('Iterations/Sec'))
        if iterations <= 0 or not math.isfinite(score) or score <= 0:
            raise ValueError('invalid iterations/score')
        if not math.isclose(score, iterations / seconds, rel_tol=0.001, abs_tol=0.000002):
            raise ValueError('score disagrees with iteration count and elapsed time')
        result = {'mode': mode, 'iterations': iterations, 'seconds': seconds,
                  'iterations_per_second': score, 'compiler': field('Compiler version'),
                  'compiler_flags': field('Compiler flags'), 'memory_location': field('Memory location'),
                  'validated': True}
        if cpu_mhz is not None:
            if not math.isfinite(cpu_mhz) or cpu_mhz <= 0:
                raise ValueError('CPU MHz must be positive and finite')
            result.update(cpu_mhz=cpu_mhz, coremark_per_mhz=score / cpu_mhz)
        for label, name in [('Timed CPU cycles', 'cycles'), ('Timed retired instructions', 'retired_instructions')]:
            match = re.search(r'^' + re.escape(label) + r': (0x[0-9a-fA-F]+)', block, re.M)
            if match:
                result[name] = int(match[1], 16)
        if 'cycles' in result and 'retired_instructions' in result:
            if result['retired_instructions'] <= 0:
                raise ValueError('retired instruction count is zero')
            result['cpi'] = result['cycles'] / result['retired_instructions']
        reports.append(result)
    if not reports:
        raise ValueError('no valid CoreMark reports found')
    return reports


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--cpu-mhz', type=float)
    parser.add_argument('--skip-short-runs', action='store_true', help='exclude explicitly marked calibration pilots')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    results = parse_reports(args.log.read_text(), args.cpu_mhz, args.skip_short_runs)
    encoded = json.dumps(results, indent=2) + '\n'
    if args.output:
        args.output.write_text(encoded)
    else:
        print(encoded, end='')


if __name__ == '__main__':
    main()
