import json
import unittest
from pathlib import Path

from damage_detector import classify_panel, estimate_severity, synthetic_damage_scene


class DamageDetectorTest(unittest.TestCase):
    def test_classify_panel_regions(self):
        panel, z = classify_panel(0.5, 0.3)
        self.assertEqual(panel, "HOOD")
        self.assertGreater(z, 0)

        panel, z = classify_panel(0.2, 0.7)
        self.assertEqual(panel, "FRONT_BUMPER")

        panel, z = classify_panel(0.8, 0.7)
        self.assertEqual(panel, "REAR_BUMPER")

    def test_estimate_severity_and_actions(self):
        sev, act, hours = estimate_severity(2.0, "SCRATCH")
        self.assertEqual(sev, "MINOR")
        self.assertEqual(act, "BUFF")
        self.assertLessEqual(hours, 1.5)

        sev, act, hours = estimate_severity(12.0, "DENT")
        self.assertEqual(sev, "MODERATE")
        self.assertEqual(act, "REPAIR")

        sev, act, hours = estimate_severity(55.0, "SHATTER")
        self.assertEqual(sev, "SEVERE")
        self.assertEqual(act, "REPLACE")

    def test_synthetic_damage_scene_payload_contract(self):
        result = synthetic_damage_scene()
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["damageCount"], 3)
        for item in result["damages"]:
            self.assertIn(item["damageType"], ["SCRATCH", "DENT", "CRACK", "SHATTER"])
            bbox = json.loads(item["boundingBoxJson"])
            self.assertIn("x", bbox)
            self.assertIn("width", bbox)
            anchor = json.loads(item["spatialAnchorJson"])
            self.assertIn("x", anchor)
            self.assertIn("y", anchor)
            self.assertIn("z", anchor)


if __name__ == "__main__":
    unittest.main()
