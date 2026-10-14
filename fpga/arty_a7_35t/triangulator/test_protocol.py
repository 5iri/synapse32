import json
import unittest

from protocol import mesh_record


class ProtocolTests(unittest.TestCase):
    def test_complete_mesh_followed_by_kernel_message(self):
        record = {"frame": 52, "compute_us": 7000000, "points": [], "triangles": []}
        line = "S32MESH " + json.dumps(record)
        self.assertEqual(mesh_record(line + "\r"), record)
        self.assertEqual(mesh_record(line + "[  738.952024] random: crng init done"), record)

    def test_interrupted_record_is_discarded(self):
        self.assertIsNone(mesh_record('S32MESH {"frame":52,^C'))
        self.assertIsNone(mesh_record('S32MESH {"frame":52,[  738.952024] random: crng init done'))
        self.assertIsNone(mesh_record("~ #"))

    def test_unknown_corruption_is_reported(self):
        with self.assertRaises(ValueError):
            mesh_record('S32MESH {"frame":broken}')
        with self.assertRaises(ValueError):
            mesh_record('S32MESH {"frame":52} unexpected')


if __name__ == "__main__":
    unittest.main()
