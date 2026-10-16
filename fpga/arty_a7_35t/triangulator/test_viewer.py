"""Slow FPGA frames must still have a measurable arrival rate."""
import threading
import unittest
from collections import deque
from unittest.mock import patch

from viewer import Viewer


class FrameRateTests(unittest.TestCase):
    def test_eight_second_frames_and_stopped_computation(self):
        viewer = Viewer.__new__(Viewer)
        viewer.lock = threading.Lock()
        viewer.frame = None
        viewer.receipts = deque([30.0, 38.0, 46.0])
        viewer.history = deque()
        viewer.running = True
        viewer.starting = False
        viewer.error = None
        viewer.revision = 3
        viewer.hardware = {"cpu_mhz": 50, "kernel_hz": 12}
        with patch("viewer.time.monotonic", return_value=47.0):
            self.assertAlmostEqual(viewer.state()["fps"], 0.125)
            viewer.running = False
            self.assertEqual(viewer.state()["fps"], 0)
        viewer.running = True
        with patch("viewer.time.monotonic", return_value=70.0):
            self.assertEqual(viewer.state()["fps"], 0)


if __name__ == "__main__":
    unittest.main()
