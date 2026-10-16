"""Reject invalid benchmark claims using real target reports as fixtures."""
import json
import unittest
from pathlib import Path

from report import parse_reports


class Reports(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures = json.loads((Path(__file__).parent / 'results/cacheless-50mhz.json').read_text())
        cls.performance = cls.fixtures['baremetal']['results'][0]['output']
        cls.validation = cls.fixtures['baremetal']['results'][-1]['output']

    def test_valid_performance_validation_and_normalization(self):
        reports = parse_reports(self.performance + '\n' + self.validation, 50)
        self.assertEqual([r['mode'] for r in reports], ['performance', 'validation'])
        self.assertAlmostEqual(reports[0]['coremark_per_mhz'], reports[0]['iterations_per_second'] / 50)
        self.assertGreater(reports[0]['cpi'], 0)

    def test_linux_report(self):
        result = parse_reports(self.fixtures['linux']['results'][0]['output'], 50)[0]
        self.assertEqual(result['mode'], 'performance')
        self.assertNotIn('cpi', result)

    def test_short_pilot_must_be_explicitly_excluded(self):
        pilot = self.fixtures['baremetal']['pilots'][0]['output']
        with self.assertRaises(ValueError):
            parse_reports(pilot + '\n' + self.performance)
        self.assertEqual(len(parse_reports(pilot + '\n' + self.performance, skip_short=True)), 1)

    def test_bad_crc_missing_validation_and_wrong_score(self):
        for text in [self.performance.replace('0xe714', '0xdead'),
                     self.performance.replace('Correct operation validated.', 'Errors detected'),
                     self.performance.replace('seedcrc          : 0xe9f5', 'seedcrc          : 0xffff'),
                     self.performance.replace('Iterations/Sec   :', 'Missing field    :'),
                     self.performance + '\nS32_BAREMETAL_TRAP cause=00000002']:
            with self.assertRaises(ValueError):
                parse_reports(text)


if __name__ == '__main__':
    unittest.main()
