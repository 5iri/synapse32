#!/usr/bin/env python3
"""Check independent dataset oracles and reject corrupted/incomplete captures."""
import copy
import json
import os
from pathlib import Path
import subprocess
import unittest

from report import parse_run, expected_checksums


def fixture():
    config = {'schema': 1, 'build_id': 'fixture', 'zlib': '1.3.2', 'sqlite': '3.54.1',
              'iterations': 1, 'input_bytes': 65536, 'rows': 1024,
              'compression_level': 6, 'database': 'memory', 'clock': 'CLOCK_MONOTONIC'}
    data = [('zlib_compress', 1, 65536, 2298676357, 9629),
            ('zlib_decompress', 16, 1048576, 2298676357, 65536),
            ('sqlite_insert', 1, 1024, 509976, 0),
            ('sqlite_queries', 1, 130, 321362488, 0)]
    records = [{'schema': 1, 'case': name, 'iterations': iterations, 'elapsed_ns': 100000,
                'units': units, 'checksum': checksum, 'output_bytes': size, 'validated': True}
               for name, iterations, units, checksum, size in data]
    return ['S32_WORKLOAD_CONFIG ' + json.dumps(config),
            *['S32_WORKLOAD ' + json.dumps(record) for record in records], 'S32_WORKLOAD_DONE 0']


class ReportTests(unittest.TestCase):
    def test_independent_oracles(self):
        # Constants independently derived and confirmed by the native executable.
        self.assertEqual(expected_checksums(1), (2298676357, 2298676357, 509976, 321362488))
        self.assertEqual(expected_checksums(100)[3], 32136248800)
        run = parse_run(fixture())
        self.assertEqual(len(run['cases']), 4)

    def test_corrupted_output_and_timing(self):
        for key, value in [('checksum', 123), ('iterations', 2), ('units', 12),
                           ('elapsed_ns', 0), ('elapsed_ns', True), ('validated', False),
                           ('output_bytes', 9630)]:
            lines = fixture()
            record = json.loads(lines[1].split(' ', 1)[1])
            record[key] = value
            lines[1] = 'S32_WORKLOAD ' + json.dumps(record)
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                parse_run(lines)

    def test_incomplete_duplicate_reordered_and_failed(self):
        lines = fixture()
        variants = [lines[:-1], lines + [lines[-1]], lines[:2] + [lines[1]] + lines[2:],
                    lines[:1] + [lines[2], lines[1]] + lines[3:],
                    lines[:-1] + ['S32_WORKLOAD_DONE 1'],
                    lines + ['S32_WORKLOAD_ERROR roundtrip']]
        for variant in variants:
            with self.subTest(variant=variant), self.assertRaises(ValueError):
                parse_run(variant)

    def test_manifest_mismatch(self):
        manifest = {'build_id': 'other', 'sources': {'zlib': {'version': '1.3.2'}, 'sqlite': {'version': '3.54.1'}}}
        with self.assertRaises(ValueError):
            parse_run(fixture(), manifest)
        manifest['build_id'] = 'fixture'
        self.assertEqual(len(parse_run(fixture(), manifest)['cases']), 4)
        manifest = copy.deepcopy(manifest)
        manifest['sources']['sqlite']['version'] = 'old'
        with self.assertRaises(ValueError):
            parse_run(fixture(), manifest)

    @unittest.skipUnless(os.environ.get('WORKLOAD_TEST_BINARY'), 'set WORKLOAD_TEST_BINARY to exercise the native executable')
    def test_native_executable(self):
        binary = Path(os.environ['WORKLOAD_TEST_BINARY']).resolve()
        manifest = json.loads((binary.parent / 'manifest.json').read_text())
        for iterations in (1, 3):
            capture = subprocess.check_output([str(binary), str(iterations)], text=True, timeout=60)
            result = parse_run(capture.splitlines(), manifest)
            self.assertEqual(result['configuration']['iterations'], iterations)
        for count in ('0', '101', '-1', 'x'):
            result = subprocess.run([str(binary), count], capture_output=True, timeout=60)
            self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
