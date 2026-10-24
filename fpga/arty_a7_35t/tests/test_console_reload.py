"""Keep keyboard bytes out of the UART loader while following its live log."""
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import tempfile
import termios
import time
import tty
import unittest

BOARD = Path(__file__).resolve().parents[1]


class ConsoleReloadTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.log = Path(self.directory.name) / 'uart.log'
        self.log.write_bytes(b'')
        self.uart_master, self.uart_slave = pty.openpty()
        self.keyboard_master, self.keyboard_slave = pty.openpty()
        for descriptor in (self.uart_master, self.uart_slave,
                           self.keyboard_master, self.keyboard_slave):
            self.addCleanup(os.close, descriptor)
        tty.setraw(self.uart_slave)
        fcntl.flock(self.uart_slave, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.display = bytearray()

    def set_speed(self, speed):
        attributes = termios.tcgetattr(self.uart_slave)
        attributes[4] = attributes[5] = speed
        termios.tcsetattr(self.uart_slave, termios.TCSANOW, attributes)
        return termios.tcgetattr(self.uart_slave)

    def stop(self):
        if self.process.poll() is None:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                return
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=2)

    def wait_display(self, marker):
        deadline = time.monotonic() + 5
        while marker not in self.display and time.monotonic() < deadline:
            if select.select([self.keyboard_master], [], [], .05)[0]:
                self.display.extend(os.read(self.keyboard_master, 4096))
            if self.process.poll() is not None:
                break
        self.assertIn(marker, self.display, self.display.decode(errors='replace'))

    def read_uart(self, count):
        data = bytearray()
        deadline = time.monotonic() + 5
        while len(data) < count and time.monotonic() < deadline:
            if select.select([self.uart_master], [], [], .05)[0]:
                data.extend(os.read(self.uart_master, count - len(data)))
        self.assertEqual(len(data), count, self.display.decode(errors='replace'))
        return bytes(data)

    def test_loader_discards_keyboard_but_keeps_log_and_uart_settings(self):
        loading_attributes = self.set_speed(termios.B2000000)
        self.process = subprocess.Popen(
            [sys.executable, '-u', str(BOARD / 'console.py'),
             os.ttyname(self.uart_slave), '--log', str(self.log), '--input-delay', '0'],
            stdin=self.keyboard_slave, stdout=self.keyboard_slave,
            stderr=subprocess.STDOUT, start_new_session=True)
        self.addCleanup(self.stop)
        self.wait_display(b'terminal input paused')
        os.write(self.keyboard_master, b'discard this while loading\r')
        self.assertFalse(select.select([self.uart_master], [], [], .2)[0])
        self.assertEqual(termios.tcgetattr(self.uart_slave), loading_attributes)

        with self.log.open('ab') as log:
            log.write(b'LIVE_LOG_DURING_RELOAD\n')
        self.wait_display(b'LIVE_LOG_DURING_RELOAD\n')
        self.assertEqual(termios.tcgetattr(self.uart_slave), loading_attributes)

        console_attributes = self.set_speed(termios.B115200)
        self.wait_display(b'Console speed restored')
        os.write(self.keyboard_master, b'uname\r')
        self.assertEqual(self.read_uart(6), b'uname\n')
        self.assertFalse(select.select([self.uart_master], [], [], .2)[0])
        self.assertEqual(termios.tcgetattr(self.uart_slave), console_attributes)

        os.write(self.keyboard_master, b'\x1d')
        self.assertEqual(self.process.wait(timeout=5), 0)
        self.assertEqual(termios.tcgetattr(self.uart_slave), console_attributes)


if __name__ == '__main__':
    unittest.main()
