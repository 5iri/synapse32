"""Write through a companion FD while the existing UART reader retains the port."""
import os
import threading
import termios
import time
from pathlib import Path


class UartWriter:
    def __init__(self, port):
        device = os.stat(port)
        identity = f"{os.major(device.st_dev):02x}:{os.minor(device.st_dev):02x}:{device.st_ino}"
        fields = [line.split() for line in Path("/proc/locks").read_text().splitlines()]
        if not any(len(row) > 5 and row[1] == "FLOCK" and row[5] == identity for row in fields):
            raise RuntimeError("Start test_board.py --keep-open before using this UART")
        self.fd = os.open(port, os.O_WRONLY | os.O_NOCTTY | os.O_NONBLOCK)
        if termios.tcgetattr(self.fd)[4] != termios.B115200:
            os.close(self.fd)
            raise RuntimeError("Wait for FPGA Linux at 115200 baud before starting the demo")
        self.lock = threading.Lock()

    def send(self, data, delay=0.1):
        with self.lock:
            for value in data:
                deadline = time.monotonic() + 10
                while True:
                    try:
                        os.write(self.fd, bytes([value]))
                        break
                    except BlockingIOError:
                        if time.monotonic() >= deadline:
                            raise RuntimeError("UART write timeout")
                        time.sleep(0.01)
                if delay:
                    time.sleep(delay)

    def close(self):
        os.close(self.fd)


class LogLines:
    def __init__(self, path, from_start=False):
        self.file = Path(path).open("rb")
        if not from_start:
            self.file.seek(0, os.SEEK_END)
        self.pending = b""

    def read(self):
        self.pending += self.file.read(65536)
        lines = self.pending.split(b"\n")
        self.pending = lines.pop()
        if len(self.pending) > 65536:
            self.pending = self.pending[-65536:]
        return [line.decode("utf-8", errors="replace").strip("\r") for line in lines]

    def wait(self, predicate, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for line in self.read():
                if predicate(line):
                    return line
            time.sleep(0.02)
        raise RuntimeError("Timed out waiting for the FPGA UART response")

    def close(self):
        self.file.close()
