from __future__ import annotations

import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
PROJECT = SCRIPTS.parent / "Termind.xcodeproj" / "project.pbxproj"


def load_script():
    path = SCRIPTS / "bump-version.py"
    spec = importlib.util.spec_from_file_location("bump_version", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


bump_version = load_script()


class VersionCalculationTests(unittest.TestCase):
    def test_semantic_bumps(self) -> None:
        self.assertEqual(bump_version.next_version("1.10.3", "patch"), "1.10.4")
        self.assertEqual(bump_version.next_version("1.10.3", "minor"), "1.11.0")
        self.assertEqual(bump_version.next_version("1.10.3", "major"), "2.0.0")
        self.assertEqual(bump_version.next_version("1.10.3", "2.1.0"), "2.1.0")

    def test_invalid_version_is_rejected(self) -> None:
        for value in ("1.2", "v1.2.3", "1.02.3", "one.two.three"):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    bump_version.next_version("1.10.3", value)


class ProjectUpdateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.project = Path(self.temporary_directory.name) / "project.pbxproj"
        shutil.copy2(PROJECT, self.project)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_updates_all_scopes_and_aligns_widgets_with_tfi(self) -> None:
        original = self.project.read_text(encoding="utf-8")
        widgets = next(scope for scope in bump_version.SCOPES if scope.name == "Widgets")
        drifted = bump_version._update_scope(
            original, widgets, bump_version.VersionState("8.0.0", 99)
        )
        self.project.write_text(drifted, encoding="utf-8")
        before, expected = bump_version.bump_project(self.project, "9.8.7")
        updated = self.project.read_text(encoding="utf-8")

        self.assertNotEqual(updated, drifted)
        for scope in bump_version.SCOPES:
            self.assertEqual(bump_version.read_state(updated, scope), expected[scope.name])
        self.assertEqual(expected["Project"].build, before["Project"].build + 1)
        self.assertEqual(expected["TFM"].build, before["TFM"].build + 1)
        self.assertEqual(expected["TFI"].build, before["TFI"].build + 1)
        self.assertEqual(expected["Widgets"], expected["TFI"])
        self.assertTrue(all(state.marketing_version == "9.8.7" for state in expected.values()))

    def test_dry_run_leaves_project_unchanged(self) -> None:
        original = self.project.read_bytes()
        _, expected = bump_version.bump_project(self.project, "patch", write=False)

        self.assertEqual(self.project.read_bytes(), original)
        self.assertEqual(
            expected["Widgets"],
            expected["TFI"],
        )

    def test_build_only_preserves_versions_and_aligns_widgets(self) -> None:
        original = self.project.read_text(encoding="utf-8")
        before, expected = bump_version.bump_project(self.project, "build")
        updated = self.project.read_text(encoding="utf-8")

        for name in ("Project", "TFM", "TFI"):
            self.assertEqual(expected[name].marketing_version, before[name].marketing_version)
            self.assertEqual(expected[name].build, before[name].build + 1)
        self.assertEqual(expected["Widgets"], expected["TFI"])
        for scope in bump_version.SCOPES:
            self.assertEqual(bump_version.read_state(updated, scope), expected[scope.name])
        self.assertNotEqual(updated, original)


if __name__ == "__main__":
    unittest.main()
