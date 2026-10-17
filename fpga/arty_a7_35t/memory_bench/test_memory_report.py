import json
import unittest

from memory_report import parse_report


def case(name='loads', **fields):
    record = dict(case=name, cycles=200, instructions=100, operations=64, validated=True)
    record.update(fields)
    return 'S32_MEMORY_BENCH ' + json.dumps(record)


class Reports(unittest.TestCase):
    def test_repeated_complete_runs(self):
        text = '\n'.join([case(), 'S32_MEMORY_BENCH_DONE:0',
                          case(cycles=204), 'S32_MEMORY_BENCH_DONE:0'])
        result = parse_report(text, 2, expected_cases=('loads',))
        self.assertEqual(result['summary'][0]['median_cycles'], 202)
        self.assertEqual(result['summary'][0]['median_cycles_per_operation'], 202 / 64)

    def test_incomplete_failed_duplicate_and_malformed_runs_rejected(self):
        for text in (case(), case() + '\nS32_MEMORY_BENCH_DONE:1',
                     case() + '\n' + case() + '\nS32_MEMORY_BENCH_DONE:0',
                     case(validated=False) + '\nS32_MEMORY_BENCH_DONE:0',
                     case(cycles=0) + '\nS32_MEMORY_BENCH_DONE:0',
                     case() + '\nS32_MEMORY_BENCH_TRAP:2'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                parse_report(text, 1, expected_cases=('loads',))

    def test_different_cases_across_runs_rejected(self):
        with self.assertRaises(ValueError):
            parse_report('\n'.join([case('loads'), 'S32_MEMORY_BENCH_DONE:0',
                                    case('stores'), 'S32_MEMORY_BENCH_DONE:0']), 2, expected_cases=('loads',))

    def test_complete_marker_cannot_hide_missing_cases(self):
        with self.assertRaises(ValueError):
            parse_report(case() + '\nS32_MEMORY_BENCH_DONE:0', 1)


if __name__ == '__main__':
    unittest.main()
