#!/usr/bin/env python3
"""Local browser viewer for meshes computed by FPGA Linux and logged over UART."""
import argparse
import json
import re
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from uart_link import LogLines, UartWriter
from protocol import mesh_record


class Viewer:
    def __init__(self, port, log, binary):
        self.writer = UartWriter(port)
        self.lines = LogLines(log)
        self.binary = binary
        self.lock = threading.Lock()
        self.control_lock = threading.Lock()
        self.frame = None
        self.receipts = deque(maxlen=60)
        self.history = deque(maxlen=60)
        self.running = False
        self.starting = False
        self.error = None
        self.revision = 0
        self.start_deadline = 0
        self.closed = threading.Event()
        self.thread = threading.Thread(target=self.capture, daemon=True)
        self.thread.start()

    def capture(self):
        while not self.closed.is_set():
            for line in self.lines.read():
                if line == "S32DONE":
                    with self.lock:
                        self.running = self.starting = False
                if not line.startswith("S32MESH "):
                    continue
                try:
                    frame = mesh_record(line)
                    if frame is None:
                        continue
                    points, triangles = frame["points"], frame["triangles"]
                    assert 3 <= len(points) <= 64 and len(triangles) <= 136
                    assert isinstance(frame["frame"], int) and frame["frame"] >= 0
                    assert isinstance(frame["compute_us"], int) and frame["compute_us"] >= 0
                    assert all(len(p) == 2 and all(isinstance(v, int) for v in p)
                               and 0 <= p[0] <= 640 and 0 <= p[1] <= 400 for p in points)
                    assert all(len(t) == 3 and len(set(t)) == 3
                               and all(isinstance(i, int) and 0 <= i < len(points) for i in t)
                               for t in triangles)
                except (ValueError, KeyError, TypeError, AssertionError):
                    with self.lock:
                        if self.running and not self.starting:
                            self.error = "Received an invalid mesh from the FPGA"
                    continue
                with self.lock:
                    self.frame = frame
                    self.revision += 1
                    self.receipts.append(time.monotonic())
                    self.history.append(frame["compute_us"] / 1000)
                    self.starting = False
                    self.error = None
            self.closed.wait(0.02)

    def state(self):
        with self.lock:
            if self.starting and time.monotonic() > self.start_deadline:
                self.starting = False
                self.error = "The FPGA has not returned a mesh. Try a smaller workload."
            fps = 0
            age = time.monotonic() - self.receipts[-1] if self.receipts else None
            if self.running and len(self.receipts) > 1:
                interval = (self.receipts[-1] - self.receipts[0]) / (len(self.receipts) - 1)
                # A fixed five-second window incorrectly reports zero for
                # valid large meshes arriving every eight seconds or more.
                if interval > 0 and age <= max(5, 2 * interval):
                    fps = 1 / interval
            return {"mesh": self.frame, "fps": fps, "history": list(self.history),
                    "age": age,
                    "running": self.running, "starting": self.starting, "error": self.error,
                    "revision": self.revision}

    def control(self, action, points=16):
        # A worker serializes commands so HTTP polling remains responsive.
        with self.control_lock:
            try:
                with self.lock:
                    previous = self.running or self.starting
                    self.running = self.starting = False
                    self.error = None
                if previous:
                    self.writer.send(b"\x03")
                    time.sleep(0.3)
                if action == "start":
                    with self.lock:
                        self.running = self.starting = True
                        self.start_deadline = time.monotonic() + 90
                        self.error = None
                        self.receipts.clear()
                        self.history.clear()
                    self.writer.send(f"{self.binary} --points {points}\n".encode())
                else:
                    with self.lock:
                        self.running = self.starting = False
            except (OSError, RuntimeError) as error:
                with self.lock:
                    self.error = str(error)
                    self.running = self.starting = False

    def close(self):
        if self.running or self.starting:
            self.control("stop")
        self.closed.set()
        self.thread.join(timeout=1)
        self.writer.close()
        self.lines.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default="/dev/ttyUSB1")
    parser.add_argument("--log", type=Path, required=True, help="log of the retained UART reader")
    parser.add_argument("--binary", default="/tmp/triangulator")
    parser.add_argument("--http-port", type=int, default=8765)
    parser.add_argument("--start", action="store_true")
    parser.add_argument("--points", type=int, choices=(16, 32, 64), default=16)
    args = parser.parse_args()
    if not re.fullmatch(r"/[A-Za-z0-9_./-]+", args.binary):
        parser.error("binary must be an absolute Linux path without shell characters")
    viewer = Viewer(args.port, args.log, args.binary)
    page = Path(__file__).with_name("index.html").read_bytes()

    class Handler(BaseHTTPRequestHandler):
        def respond(self, status, body, content_type="application/json"):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/":
                self.respond(200, page, "text/html; charset=utf-8")
            elif self.path == "/api/state":
                self.respond(200, json.dumps(viewer.state()).encode())
            else:
                self.respond(404, b'{}')

        def do_POST(self):
            origin = self.headers.get("Origin")
            allowed = {f"http://127.0.0.1:{args.http_port}", f"http://localhost:{args.http_port}"}
            if origin is not None and origin not in allowed:
                self.respond(403, b'{"error":"Origin rejected"}')
                return
            if self.path not in ("/api/start", "/api/stop"):
                self.respond(404, b'{}')
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 <= length <= 1024:
                    raise ValueError()
                data = json.loads(self.rfile.read(length) or b"{}")
                points = data.get("points", 16)
                if not isinstance(points, int) or points not in (16, 32, 64):
                    raise ValueError()
            except (ValueError, TypeError, AttributeError):
                self.respond(400, b'{"error":"Choose 16, 32 or 64 points"}')
                return
            action = self.path.rsplit("/", 1)[-1]
            threading.Thread(target=viewer.control, args=(action, points), daemon=True).start()
            self.respond(202, b'{"accepted":true}')

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", args.http_port), Handler)
    if args.start:
        threading.Thread(target=viewer.control, args=("start", args.points), daemon=True).start()
    print(f"Synapse32 mesh viewer: http://127.0.0.1:{args.http_port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        viewer.close()


if __name__ == "__main__":
    main()
