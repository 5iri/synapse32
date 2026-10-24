"""Exercise the host reboot loop over a real PTY, without FPGA/JTAG access."""
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import time
import tty
import unittest
import zlib

BOARD = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BOARD))
from test_board import RebootDetector
from upload import frame

HARNESS = """
import os, sys, time
sys.path.insert(0, sys.argv.pop(1))
import serial, test_board
def record(value):
    with open(os.environ['REBOOT_TEST_EVENTS'], 'a') as output:
        output.write(value + '\\n')
def program(bitstream, *args, **kwargs):
    record('program ' + str(bitstream))
real_serial = serial.Serial
def open_serial(*args, **kwargs):
    record('serial')
    port = real_serial(*args, **kwargs)
    if os.environ['REBOOT_TEST_WAIT_ACK'] == '1':
        real_write = port.write
        def write(data):
            count = real_write(data)
            if data.startswith(b'S32!'):
                deadline = time.monotonic() + 2
                while not port.in_waiting and time.monotonic() < deadline:
                    time.sleep(.001)
            return count
        port.write = write
    return port
test_board.program_bitstream = program
serial.Serial = open_serial
test_board.main()
"""


class BoardRebootTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.work = Path(self.directory.name)
        self.image = self.work / 'payload.bin'
        self.image.write_bytes(bytes(range(251)) * 131 + b'!')
        self.packet = frame(self.image.read_bytes())
        self.bitstream = self.work / 'board.bit'
        self.bitstream.write_bytes(b'fake bitstream')
        self.events = self.work / 'events'
        self.log = self.work / 'uart.log'
        self.output = self.work / 'host.out'
        self.master, self.slave = pty.openpty()
        tty.setraw(self.slave)
        self.addCleanup(os.close, self.master)
        self.addCleanup(os.close, self.slave)

    def start(self, *options, wait_ack=False):
        output = self.output.open('wb')
        self.addCleanup(output.close)
        self.process = subprocess.Popen(
            [sys.executable, '-u', '-c', HARNESS, str(BOARD),
             os.ttyname(self.slave), str(self.image), '--timeout', '4',
             '--input-delay', '0', '--log', str(self.log), *map(str, options)],
            env={**os.environ, 'REBOOT_TEST_EVENTS': str(self.events),
                 'REBOOT_TEST_WAIT_ACK': str(int(wait_ack))},
            stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        self.addCleanup(self.stop)

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

    def records(self):
        return self.events.read_text().splitlines() if self.events.exists() else []

    def read(self, count):
        result = bytearray()
        deadline = time.monotonic() + 6
        while len(result) < count and time.monotonic() < deadline:
            if select.select([self.master], [], [], 0.05)[0]:
                result.extend(os.read(self.master, count - len(result)))
            if self.process.poll() is not None:
                break
        self.assertEqual(len(result), count, self.output.read_text())
        return bytes(result)

    def upload(self, programmed=False, prompt=False):
        header = self.read(8)
        self.assertEqual(header[:4], b'S32!')
        length, = struct.unpack('<I', header[4:])
        self.assertEqual(length, len(self.packet) - 12)
        body = self.read(length + 4)
        self.assertEqual(zlib.crc32(body[:-4]), struct.unpack('<I', body[-4:])[0])
        self.assertEqual(header + body, self.packet)
        expected = ['program ' + str(self.bitstream)] if programmed else []
        self.assertEqual(self.records(), expected + ['serial'])
        os.write(self.master, b'K' + (b'boot 1\r\n~ # ' if prompt else b''))
        time.sleep(0.1)

    def shell(self, number, prompt=True, reboot=False):
        if prompt:
            os.write(self.master, f'boot {number}\r\n~ # '.encode())
        command = b'echo FPGA_BOOT_OK; uname -a\n'
        self.assertEqual(self.read(len(command)), command)
        proof = b'\r\nFPGA_BOOT_OK\r\nLinux test 6.10 #1 riscv32 GNU/Linux\r\n'
        os.write(self.master, proof + (b'[ 4.000000] reboot: Restarting system\r\n' if reboot else b'~ # '))
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if self.output.read_text().count('PASS:') >= number:
                return
            time.sleep(0.02)
        self.fail(self.output.read_text())

    def reboot(self):
        os.write(self.master, b'\r\n[    3.000000] rebo')
        self.assertFalse(select.select([self.master], [], [], 0.2)[0])
        os.write(self.master, b'ot: Restarting system')
        self.assertFalse(select.select([self.master], [], [], 0.2)[0])
        os.write(self.master, b'\r\n')

    def test_reboot_keeps_serial_and_reuploads_frozen_payload(self):
        self.start('--auto-reboot', '--program-bitstream', self.bitstream)
        self.upload(programmed=True)
        self.image.write_bytes(b'changed after first upload')
        self.shell(1)
        os.write(self.master, b'\r\ndebug: [ 1.000] reboot: Restarting system\r\n'
                 b'reboot: Restarting system\r\n[ 2.000] reboot: Restarting system later\r\n')
        self.assertFalse(select.select([self.master], [], [], 1.3)[0])
        self.reboot()
        self.upload(programmed=True)
        self.shell(2)
        self.assertEqual(self.process.poll(), None)
        capture = self.log.read_bytes()
        self.assertIn(b'boot 1', capture)
        self.assertIn(b'boot 2', capture)
        self.assertEqual(capture.count(b'\nFPGA_BOOT_OK\r\n'), 2)

    def test_console_only_attaches_then_uploads_on_reboot(self):
        self.start('--auto-reboot', '--console-only')
        self.assertEqual(self.read(1), b'\n')
        self.shell(1)
        self.reboot()
        self.upload()
        self.shell(2)
        self.assertEqual(self.records(), ['serial'])

    def test_reboot_is_opt_in(self):
        self.start('--keep-open')
        self.upload()
        self.shell(1)
        self.reboot()
        self.assertFalse(select.select([self.master], [], [], 1.3)[0])
        self.assertEqual(self.records(), ['serial'])

    def test_ack_can_arrive_with_boot_prompt(self):
        self.image.write_bytes(b'coalesced ACK payload')
        self.packet = frame(self.image.read_bytes())
        self.start(wait_ack=True)
        self.upload(prompt=True)
        self.shell(1, prompt=False)
        self.assertEqual(self.process.wait(timeout=2), 0)
        self.assertIn(b'boot 1', self.log.read_bytes())

    def test_proof_and_reboot_can_share_a_console_read(self):
        self.start('--auto-reboot', '--console-only')
        self.assertEqual(self.read(1), b'\n')
        self.shell(1, reboot=True)
        self.upload()
        self.shell(2)


class RebootDetectorTest(unittest.TestCase):
    def test_complete_kernel_line_only(self):
        for noise in (b'reboot: Restarting system\n',
                      b'echo [ 1.000] reboot: Restarting system\n',
                      b'[ 1.000] debug reboot: Restarting system\n',
                      b'[ 1.000] reboot: Restarting system later\n'):
            self.assertFalse(RebootDetector().feed(noise))
        detector = RebootDetector()
        self.assertFalse(detector.feed(b'noise\r\n[    1.000000] rebo'))
        self.assertFalse(detector.feed(b'ot: Restarting system\r'))
        self.assertTrue(detector.feed(b'\n'))


if __name__ == '__main__':
    unittest.main()
