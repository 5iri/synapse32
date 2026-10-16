"""Execute the platform's real C timer conversion against an exact integer oracle."""
import ctypes
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import tempfile
import unittest


UINT64_MASK = (1 << 64) - 1
UINT32_MASK = (1 << 32) - 1
CLOCKS = (1000, 1001, 1000000, 50000000, 58823529, 62500000, UINT32_MASK)


def get_time_source():
    """Copy the function body, including its actual preprocessor branches."""
    source = (Path(__file__).parent / 'baremetal/port.c').read_text()
    start = re.search(r'CORE_TICKS\s+get_time\s*\(\s*void\s*\)\s*\{', source)
    if start is None:
        raise AssertionError('The bare-metal port must define CORE_TICKS get_time(void)')
    depth = 1
    end = start.end()
    while depth and end < len(source):
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    if depth:
        raise AssertionError('Unterminated get_time function')
    return source[start.start():end]


class BaremetalTimer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which(os.environ.get('HOST_CC', 'cc'))
        if compiler is None:
            raise unittest.SkipTest('A native C compiler is required (cc or HOST_CC)')
        cls.directory = tempfile.TemporaryDirectory(prefix='coremark-timer-')
        cls.addClassCleanup(cls.directory.cleanup)
        directory = Path(cls.directory.name)
        source = directory / 'timer.c'
        source.write_text(
            '#include <stdint.h>\n'
            'typedef uint32_t CORE_TICKS;\n'
            'static uint64_t timer_start, timer_stop;\n'
            + get_time_source()
            + '\nuint32_t evaluate(uint64_t start, uint64_t stop) {\n'
              '    timer_start = start; timer_stop = stop; return get_time();\n'
              '}\n'
        )
        cls.libraries = {}
        cls.conversions = {}
        for hz in CLOCKS:
            library_path = directory / f'timer-{hz}.so'
            result = subprocess.run(
                [compiler, '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                 '-shared', '-fPIC', f'-DCPU_CLOCK_HZ={hz}', str(source),
                 '-o', str(library_path)], capture_output=True, text=True,
            )
            if result.returncode:
                raise AssertionError(f'Host compilation failed for {hz} Hz:\n{result.stderr}')
            library = ctypes.CDLL(str(library_path))
            library.evaluate.argtypes = (ctypes.c_uint64, ctypes.c_uint64)
            library.evaluate.restype = ctypes.c_uint32
            cls.libraries[hz] = library
            cls.conversions[hz] = library.evaluate

    def assert_conversion(self, hz, elapsed, start=0):
        stop = (start + elapsed) & UINT64_MASK
        # Python multiplication is intentionally unbounded. The C function must
        # reproduce this result despite its fixed-width arithmetic and counters.
        expected = (((stop - start) & UINT64_MASK) * 1000 // hz) & UINT32_MASK
        self.assertEqual(self.conversions[hz](start, stop), expected,
                         f'clock={hz} start={start} stop={stop} elapsed={elapsed}')

    def test_millisecond_second_and_coremark_duration_boundaries(self):
        for hz in CLOCKS:
            for milliseconds in (1, 2, 999, 1000, 1001, 9999, 10000, 10001, 15000):
                first_cycle = (milliseconds * hz + 999) // 1000
                for elapsed in (first_cycle - 1, first_cycle, first_cycle + 1):
                    with self.subTest(clock=hz, ms=milliseconds, elapsed=elapsed):
                        self.assert_conversion(hz, elapsed)
            self.assert_conversion(hz, 0)

    def test_nonzero_origins_and_64_bit_mtime_rollover(self):
        for hz in CLOCKS:
            for elapsed in (1, hz - 1, hz, 10 * hz, (1 << 32) + 17, UINT64_MASK):
                for start in (1, (1 << 32) - 11, (1 << 63) - 7, UINT64_MASK - 9):
                    with self.subTest(clock=hz, start=start, elapsed=elapsed):
                        self.assert_conversion(hz, elapsed, start)

    def test_long_durations_do_not_overflow_cycles_times_1000(self):
        unsafe_threshold = UINT64_MASK // 1000
        for hz in CLOCKS:
            for elapsed in (unsafe_threshold - 1, unsafe_threshold,
                            unsafe_threshold + 1, UINT64_MASK // 2, UINT64_MASK):
                with self.subTest(clock=hz, elapsed=elapsed):
                    self.assert_conversion(hz, elapsed)
        # Ensure the cases distinguish an unsafe uint64_t elapsed*1000 rewrite.
        hz = 58823529
        exact = (UINT64_MASK * 1000 // hz) & UINT32_MASK
        overflowed = (((UINT64_MASK * 1000) & UINT64_MASK) // hz) & UINT32_MASK
        self.assertNotEqual(exact, overflowed)

    def test_32_bit_core_ticks_rollover(self):
        for hz in CLOCKS:
            for milliseconds in (UINT32_MASK, 1 << 32, (1 << 32) + 1, 1 << 33):
                first_cycle = (milliseconds * hz + 999) // 1000
                for elapsed in (first_cycle - 1, first_cycle, first_cycle + 1):
                    with self.subTest(clock=hz, ms=milliseconds, elapsed=elapsed):
                        self.assert_conversion(hz, elapsed)
                self.assertEqual(self.conversions[hz](0, first_cycle),
                                 milliseconds & UINT32_MASK)

    def test_deterministic_full_width_counter_samples(self):
        samples = random.Random(0x53333250)
        for hz in CLOCKS:
            for _ in range(128):
                self.assert_conversion(hz, samples.getrandbits(64), samples.getrandbits(64))


if __name__ == '__main__':
    unittest.main()
