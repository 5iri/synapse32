"""Strict validation and summary of the deterministic workload protocol."""
import json
import statistics

CASES = ('zlib_compress', 'zlib_decompress', 'sqlite_insert', 'sqlite_queries')


def input_checksum():
    text = b'synapse32 sensor log: temperature=024 pressure=1013 state=ready\n'
    random, checksum = 0x12345678, 2166136261
    for index in range(65536):
        random ^= (random << 13) & 0xffffffff
        random ^= random >> 17
        random ^= (random << 5) & 0xffffffff
        value = text[index % len(text)] if index % 257 < 224 else random & 255
        checksum = ((checksum ^ value) * 16777619) & 0xffffffff
    return checksum


def expected_checksums(iterations):
    values = [(index * 37 + 11) % 1000 for index in range(1024)]
    lookup = sum(values[(index * 17) % 1024] for index in range(128))
    joined = sum(value * values[(index + 1) % 1024] for index, value in enumerate(values))
    checksum = input_checksum()
    return (checksum, checksum, sum(values), (lookup + sum(values) + 1024 + joined) * iterations)


def positive_integer(value, name):
    if type(value) is not int or value <= 0:
        raise ValueError(f'{name} must be a positive integer')
    return value


def parse_run(lines, manifest=None):
    configs, records, done = [], [], []
    sequence = []
    for line in lines:
        if line.startswith('S32_WORKLOAD_ERROR'):
            raise ValueError(line)
        for prefix, target, kind in [('S32_WORKLOAD_CONFIG ', configs, 'config'),
                                      ('S32_WORKLOAD ', records, 'record')]:
            if line.startswith(prefix):
                target.append(json.loads(line[len(prefix):]))
                sequence.append(kind)
        if line.startswith('S32_WORKLOAD_DONE '):
            done.append(line)
            sequence.append('done')
    if sequence != ['config', 'record', 'record', 'record', 'record', 'done'] or done != ['S32_WORKLOAD_DONE 0']:
        raise ValueError('Incomplete, duplicated or out-of-order workload run')
    config = configs[0]
    count = positive_integer(config.get('iterations'), 'iterations')
    if count > 100 or config.get('schema') != 1 or config.get('input_bytes') != 65536 or config.get('rows') != 1024:
        raise ValueError('Unexpected dataset configuration')
    if config.get('compression_level') != 6 or config.get('database') != 'memory' or config.get('clock') != 'CLOCK_MONOTONIC':
        raise ValueError('Unexpected workload configuration')
    if manifest:
        if config.get('build_id') != manifest['build_id']:
            raise ValueError('Workload executable does not match the supplied build manifest')
        for library in ('zlib', 'sqlite'):
            if config.get(library) != manifest['sources'][library]['version']:
                raise ValueError(f'Unexpected {library} version')
    checksums = expected_checksums(count)
    iterations = (count, count * 16, count, count)
    units = (65536 * count, 65536 * count * 16, 1024 * count, 130 * count)
    for index, record in enumerate(records):
        if record.get('case') != CASES[index] or record.get('schema') != 1 or record.get('validated') is not True:
            raise ValueError('Unexpected or unvalidated workload case')
        for key, expected in [('iterations', iterations[index]), ('units', units[index]), ('checksum', checksums[index])]:
            if type(record.get(key)) is not int or record[key] != expected:
                raise ValueError(f"Wrong {record['case']} {key}")
        positive_integer(record.get('elapsed_ns'), 'elapsed_ns')
        output = record.get('output_bytes')
        # The pinned scalar zlib release and fixed dataset produce this stream length.
        if type(output) is not int or (index == 0 and output != 9629) or (index == 1 and output != 65536) or (index > 1 and output != 0):
            raise ValueError('Unexpected output size')
        record['units_per_second'] = record['units'] * 1e9 / record['elapsed_ns']
        record['unit'] = 'input_bytes' if index < 2 else ('inserted_rows' if index == 2 else 'SQL_statements')
    return {'configuration': config, 'cases': records}


def summarize(runs):
    return {name: {'median_seconds': statistics.median(run['cases'][index]['elapsed_ns'] / 1e9 for run in runs),
                   'median_units_per_second': statistics.median(run['cases'][index]['units_per_second'] for run in runs),
                   'unit': runs[0]['cases'][index]['unit']}
            for index, name in enumerate(CASES)}


def main():
    import argparse
    from pathlib import Path
    parser = argparse.ArgumentParser(description='Validate one workload transcript and write a JSON report')
    parser.add_argument('log', type=Path)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    run = parse_run(args.log.read_text().splitlines(), json.loads(args.manifest.read_text()))
    result = {'schema': 1, 'runs': [run], 'summary': summarize([run]), 'completed': True}
    encoded = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded)
    else:
        print(encoded, end='')


if __name__ == '__main__':
    main()
