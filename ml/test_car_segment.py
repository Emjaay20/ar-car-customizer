import tempfile
import unittest
from pathlib import Path

from car_segment import gray_rows, prove_synthetic, read_png, refine_paint_mask, synthetic_scene, write_png


class PaintIsolationTest(unittest.TestCase):
    def test_synthetic_car_excludes_window_and_wheels(self):
        summary = prove_synthetic()
        self.assertGreater(summary["paintPixels"], 0)
        self.assertEqual(len([point for point in summary["points"] if point["name"] == "wheel"]), 2)

    def test_empty_mask_has_no_keypoints(self):
        image, mask = synthetic_scene()
        blank = [[0 for _ in row] for row in mask]
        paint, points = refine_paint_mask(image, blank)
        self.assertEqual(sum(sum(row) for row in paint), 0)
        self.assertEqual(points, [])

    def test_gray_mask_roundtrip(self):
        summary = prove_synthetic()
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "mask.png"
            write_png(path, summary["width"], summary["height"], gray_rows(summary["paint"]), 0)
            width, height, color_type, rows = read_png(path)
        self.assertEqual((width, height, color_type), (summary["width"], summary["height"], 0))
        self.assertEqual(rows[25][40], 0)
        self.assertEqual(rows[36][18], 255)


if __name__ == "__main__":
    unittest.main()
