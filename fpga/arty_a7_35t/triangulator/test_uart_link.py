"""Regression for BusyBox prompts prefixed to echo-disabled UART responses."""
import tempfile
import unittest
from pathlib import Path

from uart_link import LogLines


class ConsoleLinesTest(unittest.TestCase):
    def test_prompt_prefixed_ack_and_command_output(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'uart.log'
            path.write_bytes(b'~ # S32_UPLOAD_EMPTY\r\n'
                             b'/tmp # > > S32_UPLOAD_ACK_0[  682.186221] random: crng init done\r\n'
                             b'~ # ~ # S32_EXTRACT:0\r\n'
                             b'~ # echo S32_UPLOAD_READY\r\n'
                             b'S32_UPLOAD_READY\r\n'
                             b'S32MESH {"frame":0}\r\n')
            lines = LogLines(path, from_start=True)
            try:
                self.assertEqual(lines.read(), ['S32_UPLOAD_EMPTY', 'S32_UPLOAD_ACK_0',
                                 '[  682.186221] random: crng init done',
                                 'S32_EXTRACT:0', 'echo S32_UPLOAD_READY',
                                 'S32_UPLOAD_READY', 'S32MESH {"frame":0}'])
            finally:
                lines.close()


if __name__ == '__main__':
    unittest.main()
