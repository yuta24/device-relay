import tempfile
import unittest
from pathlib import Path

from coverage import METRICS, report


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "Shared").mkdir()
        (self.root / "Shared/Example.swift").touch()
        self.entry = {
            "filename": str(self.root / "Shared/Example.swift"),
            "summary": {m: {"count": 10, "covered": 8} for m in METRICS},
        }
        self.export = {"data": [{"files": [self.entry]}]}
        self.thresholds = {"total": {m: 80 for m in METRICS}, "areas": {"Shared": 80}}

    def test_filters_tests_and_accepts_exact_floor(self):
        excluded = dict(
            self.entry, filename=str(self.root.parent / "Tests/Example.swift")
        )
        self.export["data"][0]["files"].append(excluded)
        result, markdown = report(self.export, self.thresholds, self.root)
        self.assertEqual(result["total"]["lines"]["count"], 10)
        self.assertEqual(result["failures"], [])
        self.assertIn("80.00% (8/10)", markdown)

    def test_uses_weighted_counts_instead_of_average_percentages(self):
        (self.root / "Shared/Other.swift").touch()
        self.export["data"][0]["files"].append(
            {
                "filename": str(self.root / "Shared/Other.swift"),
                "summary": {m: {"count": 90, "covered": 90} for m in METRICS},
            }
        )
        result, _ = report(self.export, self.thresholds, self.root)
        self.assertEqual(result["total"]["lines"]["percent"], 98)

    def test_below_floor_fails_even_when_display_rounds_up(self):
        self.entry["summary"]["lines"] = {"count": 100000, "covered": 79999}
        result, _ = report(self.export, self.thresholds, self.root)
        self.assertEqual(len(result["failures"]), 2)

    def test_missing_source_is_an_error(self):
        (self.root / "Shared/New.swift").touch()
        with self.assertRaisesRegex(ValueError, "missing=.*New.swift"):
            report(self.export, self.thresholds, self.root)

    def test_empty_and_duplicate_exports_are_errors(self):
        with self.assertRaises(ValueError):
            report({"data": [{"files": []}]}, self.thresholds, self.root)
        self.export["data"][0]["files"].append(self.entry)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            report(self.export, self.thresholds, self.root)

    def add_source(self, relative_path):
        path = self.root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch()
        self.export["data"][0]["files"].append(dict(self.entry, filename=str(path)))

    def test_new_areas_require_floors_even_when_fully_exported(self):
        self.add_source("New/Example.swift")
        self.add_source("Another/Example.swift")
        with self.assertRaisesRegex(
            ValueError, "missing coverage floors for areas: Another, New"
        ):
            report(self.export, self.thresholds, self.root)

    def test_new_area_with_floor_passes(self):
        self.add_source("New/Example.swift")
        self.thresholds["areas"]["New"] = 80
        result, _ = report(self.export, self.thresholds, self.root)
        self.assertEqual(result["failures"], [])
        self.assertEqual(set(result["areas"]), {"Shared", "New"})

    def test_new_area_floor_is_enforced(self):
        self.add_source("New/Example.swift")
        self.thresholds["areas"]["New"] = 90
        result, _ = report(self.export, self.thresholds, self.root)
        self.assertEqual(result["failures"], ["New lines: 80.00% < 90.00%"])

    def test_removed_area_requires_removing_its_floor(self):
        self.thresholds["areas"]["Removed"] = 80
        with self.assertRaisesRegex(ValueError, "missing coverage area: Removed"):
            report(self.export, self.thresholds, self.root)

    def test_nested_directory_uses_top_level_area_floor(self):
        self.add_source("Shared/Nested/Example.swift")
        result, _ = report(self.export, self.thresholds, self.root)
        self.assertEqual(set(result["areas"]), {"Shared"})
        self.assertEqual(result["areas"]["Shared"]["lines"]["count"], 20)

    def test_root_file_is_in_total_without_requiring_area_floor(self):
        self.add_source("main.swift")
        result, _ = report(self.export, self.thresholds, self.root)
        self.assertEqual(set(result["areas"]), {"Shared"})
        self.assertEqual(result["total"]["lines"]["count"], 20)
