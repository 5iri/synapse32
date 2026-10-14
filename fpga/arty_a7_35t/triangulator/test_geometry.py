"""Check the mathematical result using independent exact Python predicates."""
import argparse
import ctypes
import json
import random
import subprocess
import tempfile
import unittest
from pathlib import Path


def orient(a, b, c):
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def circle(a, b, c, p):
    ax, ay = a[0] - p[0], a[1] - p[1]
    bx, by = b[0] - p[0], b[1] - p[1]
    cx, cy = c[0] - p[0], c[1] - p[1]
    return ((ax * ax + ay * ay) * (bx * cy - by * cx)
            - (bx * bx + by * by) * (ax * cy - ay * cx)
            + (cx * cx + cy * cy) * (ax * by - ay * bx))


def validate_mesh(points, triangles):
    seen = set()
    edges = {}
    twice_area = 0
    assert len(triangles) <= 2 * len(points) - 2
    for indices in triangles:
        assert len(indices) == 3 and len(set(indices)) == 3
        assert all(0 <= i < len(points) for i in indices)
        a, b, c = (points[i] for i in indices)
        assert orient(a, b, c) > 0, "degenerate or clockwise triangle"
        twice_area += orient(a, b, c)
        assert all(circle(a, b, c, point) <= 0 for point in points), "non-Delaunay triangle"
        seen.update(indices)
        for i, j in zip(indices, indices[1:] + indices[:1]):
            edge = tuple(sorted((i, j)))
            edges[edge] = edges.get(edge, 0) + 1
    assert all(count <= 2 for count in edges.values()), "non-manifold edge"
    if triangles:
        assert len({tuple(points[i]) for i in seen}) == len(set(map(tuple, points))), "missing vertex"
        assert len(seen) - len(edges) + len(triangles) == 1, "mesh has a hole or disconnected component"
        # The sum of triangle areas must cover the convex hull exactly.
        ordered = sorted(set(map(tuple, points)))
        lower, upper = [], []
        for chain, vertices in ((lower, ordered), (upper, reversed(ordered))):
            for point in vertices:
                while len(chain) >= 2 and orient(chain[-2], chain[-1], point) <= 0:
                    chain.pop()
                chain.append(point)
        hull = lower[:-1] + upper[:-1]
        hull_area = sum(a[0] * b[1] - a[1] * b[0]
                        for a, b in zip(hull, hull[1:] + hull[:1]))
        assert twice_area == hull_area, "triangles do not cover the convex hull"
    elif len(set(map(tuple, points))) >= 3:
        distinct = list(set(map(tuple, points)))
        assert all(orient(distinct[0], distinct[1], point) == 0 for point in distinct), "empty non-collinear mesh"


class Point(ctypes.Structure):
    _fields_ = [("x", ctypes.c_int32), ("y", ctypes.c_int32)]


class Triangle(ctypes.Structure):
    _fields_ = [("a", ctypes.c_int32), ("b", ctypes.c_int32), ("c", ctypes.c_int32)]


class GeometryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        library = Path(cls.directory.name) / "triangulator.so"
        subprocess.run(["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-shared", "-fPIC",
                        "-DTRIANGULATOR_KERNEL_ONLY", str(Path(__file__).with_name("triangulator.c")),
                        "-o", str(library)], check=True)
        cls.library = ctypes.CDLL(str(library))
        cls.library.triangulate.argtypes = [ctypes.POINTER(Point), ctypes.c_int, ctypes.POINTER(Triangle)]
        cls.library.triangulate.restype = ctypes.c_int

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def check_points(self, points):
        result = (Triangle * 136)()
        count = self.library.triangulate((Point * len(points))(*(Point(*p) for p in points)), len(points), result)
        self.assertGreaterEqual(count, 0)
        triangles = [[result[i].a, result[i].b, result[i].c] for i in range(count)]
        validate_mesh(points, triangles)
        return triangles

    def test_triangle_square_and_collinear(self):
        self.assertEqual(len(self.check_points([(0, 0), (640, 0), (320, 400)])), 1)
        self.assertEqual(len(self.check_points([(0, 0), (640, 0), (640, 400), (0, 400)])), 2)
        self.assertEqual(self.check_points([(20, 20), (40, 40), (60, 60), (80, 80)]), [])

    def test_thin_boundary_triangle(self):
        self.assertEqual(len(self.check_points([(503, 355), (331, 315), (572, 372)])), 1)

    def test_random_clouds_and_duplicate_vertex(self):
        generator = random.Random(532032)
        for count in (16, 32, 64):
            for _ in range(25):
                points = list({(generator.randrange(641), generator.randrange(401)) for _ in range(count)})
                self.check_points(points)
        self.check_points([(0, 0), (640, 0), (320, 400), (0, 0), (320, 200)])


def check_log(path):
    frames = []
    for line in Path(path).read_text(errors="replace").splitlines():
        if line.startswith("S32MESH "):
            frame = json.loads(line[8:])
            validate_mesh(frame["points"], frame["triangles"])
            frames.append(frame)
    if not frames:
        raise RuntimeError("No complete FPGA mesh frames found")
    print(f"Validated {len(frames)} FPGA frames; compute range "
          f"{min(f['compute_us'] for f in frames) / 1000:.3f}–"
          f"{max(f['compute_us'] for f in frames) / 1000:.3f} ms")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=Path)
    args = parser.parse_args()
    if args.log:
        check_log(args.log)
    else:
        unittest.main(argv=[__file__])
