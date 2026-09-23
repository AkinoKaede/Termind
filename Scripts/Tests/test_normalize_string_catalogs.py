from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
NORMALIZER = SCRIPTS / "normalize-string-catalogs.py"


class StringCatalogNormalizationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def run_normalizer(
        self, mode: str, *paths: Path, script: Path = NORMALIZER
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(script), mode, *(str(path) for path in paths)],
            cwd=self.directory,
            capture_output=True,
            text=True,
            check=False,
        )

    def assert_success(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def write_catalog(self, name: str, content: object) -> Path:
        path = self.directory / name
        path.write_text(json.dumps(content, ensure_ascii=False), encoding="utf-8")
        return path

    def test_check_reports_drift_without_writing(self) -> None:
        path = self.write_catalog(
            "Localizable.xcstrings",
            {
                "version": "1.0",
                "strings": {"Hello": {"extractionState": "stale"}},
                "sourceLanguage": "en",
            },
        )
        original = path.read_bytes()
        original_mtime = path.stat().st_mtime_ns

        result = self.run_normalizer("--check", path)

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(path.stat().st_mtime_ns, original_mtime)

    def test_check_detects_formatting_drift_when_entries_are_already_manual(self) -> None:
        path = self.write_catalog(
            "Formatting.xcstrings",
            {
                "sourceLanguage": "en",
                "strings": {"Hello": {"extractionState": "manual"}},
                "version": "1.0",
            },
        )
        original = path.read_bytes()

        result = self.run_normalizer("--check", path)

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(path.read_bytes(), original)

    def test_write_uses_xcode_spacing_unicode_and_no_final_newline(self) -> None:
        path = self.write_catalog(
            "Localizable.xcstrings",
            {
                "version": "1.0",
                "strings": {
                    "你好 / Hello": {
                        "extractionState": "stale",
                        "comment": "中文 / slash, \"quote\", newline\nnext",
                    }
                },
                "sourceLanguage": "en",
            },
        )

        self.assert_success(self.run_normalizer("--write", path))

        self.assertEqual(
            path.read_text(encoding="utf-8"),
            '{\n'
            '  "sourceLanguage" : "en",\n'
            '  "strings" : {\n'
            '    "你好 / Hello" : {\n'
            '      "comment" : "中文 / slash, \\"quote\\", newline\\nnext",\n'
            '      "extractionState" : "manual"\n'
            '    }\n'
            '  },\n'
            '  "version" : "1.0"\n'
            '}',
        )
        self.assert_success(self.run_normalizer("--check", path))

    def test_empty_objects_use_xcode_blank_line_format(self) -> None:
        path = self.write_catalog(
            "Empty.xcstrings",
            {"sourceLanguage": "en", "strings": {}, "version": "1.0"},
        )

        self.assert_success(self.run_normalizer("--write", path))

        self.assertEqual(
            path.read_text(encoding="utf-8"),
            '{\n'
            '  "sourceLanguage" : "en",\n'
            '  "strings" : {\n'
            '\n'
            '  },\n'
            '  "version" : "1.0"\n'
            '}',
        )

    def test_nested_empty_arrays_and_objects_keep_xcode_indentation(self) -> None:
        path = self.write_catalog(
            "EmptyMetadata.xcstrings",
            {
                "sourceLanguage": "en",
                "strings": {"Hello": {"metadata": {"emptyArray": [], "emptyObject": {}}}},
                "version": "1.0",
            },
        )

        self.assert_success(self.run_normalizer("--write", path))

        self.assertIn(
            '      "metadata" : {\n'
            '        "emptyArray" : [\n'
            '\n'
            '        ],\n'
            '        "emptyObject" : {\n'
            '\n'
            '        }\n'
            '      }',
            path.read_text(encoding="utf-8"),
        )

    def test_normalization_preserves_translations_variations_and_unknown_metadata(self) -> None:
        catalog = {
            "version": "1.2",
            "sourceLanguage": "en",
            "strings": {
                "Deleted key": {"extractionState": "stale", "comment": "Keep this entry."},
                "Items: %#@items@": {
                    "extractionState": "extracted_with_value",
                    "comment": "A count with plural forms.",
                    "shouldTranslate": True,
                    "localizations": {
                        "zh-Hant": {
                            "substitutions": {
                                "items": {
                                    "argNum": 1,
                                    "formatSpecifier": "lld",
                                    "variations": {
                                        "plural": {
                                            "other": {
                                                "stringUnit": {
                                                    "state": "translated",
                                                    "value": "%lld 個項目",
                                                }
                                            }
                                        }
                                    },
                                }
                            },
                            "stringUnit": {"state": "needs_review", "value": "項目：%#@items@"},
                        },
                        "en": {
                            "variations": {
                                "plural": {
                                    "other": {"stringUnit": {"state": "new", "value": "%lld items"}},
                                    "one": {"stringUnit": {"state": "translated", "value": "%lld item"}},
                                }
                            }
                        },
                    },
                    "metadata": {
                        "extractionState": "stale",
                        "ordered": [3, "三", {"z": False, "a": None}, ["b", "a"]],
                        "fraction": 1.25,
                        "empty": {},
                    },
                },
                "Implicit": {},
                "Already manual": {"extractionState": "manual", "shouldTranslate": False},
            },
            "metadata": {"extractionState": "root_metadata", "futureField": ["z", "a"]},
        }
        expected = copy.deepcopy(catalog)
        for entry in expected["strings"].values():
            entry["extractionState"] = "manual"
        path = self.write_catalog("Complex.xcstrings", catalog)

        self.assert_success(self.run_normalizer("--write", path))

        self.assertEqual(json.loads(path.read_text(encoding="utf-8")), expected)

    def test_every_object_uses_unicode_code_point_order(self) -> None:
        keys = ["😀", "\ue000", "中", "é", "a", "Z", "A", "", "a/b"]
        path = self.write_catalog(
            "Ordering.xcstrings",
            {
                "version": "1.0",
                "strings": {key: {"z": 1, "a": 2} for key in keys},
                "metadata": [{key: index for index, key in enumerate(keys)}],
                "sourceLanguage": "en",
            },
        )

        self.assert_success(self.run_normalizer("--write", path))

        def check_order(value: object) -> None:
            if isinstance(value, dict):
                self.assertEqual(list(value), sorted(value))
                for child in value.values():
                    check_order(child)
            elif isinstance(value, list):
                for child in value:
                    check_order(child)

        check_order(json.loads(path.read_text(encoding="utf-8")))

    def test_second_write_does_not_touch_content_or_mtime(self) -> None:
        path = self.write_catalog(
            "Stable.xcstrings",
            {"sourceLanguage": "en", "strings": {"Hello": {}}, "version": "1.0"},
        )
        self.assert_success(self.run_normalizer("--write", path))
        original = path.read_bytes()
        sentinel_mtime = 1_600_000_000_123_456_789
        os.utime(path, ns=(sentinel_mtime, sentinel_mtime))
        original_mtime = path.stat().st_mtime_ns

        self.assert_success(self.run_normalizer("--write", path))

        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(path.stat().st_mtime_ns, original_mtime)

    def test_batch_validation_finishes_before_any_file_is_written(self) -> None:
        valid_path = self.write_catalog(
            "First.xcstrings",
            {"sourceLanguage": "en", "strings": {"Hello": {}}, "version": "1.0"},
        )
        original = valid_path.read_bytes()
        original_mtime = valid_path.stat().st_mtime_ns
        invalid_path = self.directory / "Last.xcstrings"
        invalid_path.write_text('{"sourceLanguage": "en",', encoding="utf-8")
        invalid_original = invalid_path.read_bytes()

        result = self.run_normalizer("--write", valid_path, invalid_path)

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(valid_path.read_bytes(), original)
        self.assertEqual(valid_path.stat().st_mtime_ns, original_mtime)
        self.assertEqual(invalid_path.read_bytes(), invalid_original)

    def test_missing_batch_file_does_not_partially_write_or_create_files(self) -> None:
        path = self.write_catalog(
            "First.xcstrings",
            {"sourceLanguage": "en", "strings": {"Hello": {}}, "version": "1.0"},
        )
        original = path.read_bytes()
        missing = self.directory / "Missing.xcstrings"

        result = self.run_normalizer("--write", path, missing)

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(path.read_bytes(), original)
        self.assertFalse(missing.exists())

    def test_duplicate_keys_are_rejected_at_every_depth(self) -> None:
        fixtures = [
            '{"sourceLanguage":"en","sourceLanguage":"zh-Hans","strings":{},"version":"1.0"}',
            '{"sourceLanguage":"en","strings":{"Hello":{},"Hello":{}},"version":"1.0"}',
            '{"sourceLanguage":"en","strings":{"Hello":{"comment":"a","comment":"b"}},"version":"1.0"}',
            '{"sourceLanguage":"en","strings":{},"version":"1.0","metadata":[{"a":1,"a":2}]}',
            '{"sourceLanguage":"en","strings":{},"version":"1.0","metadata":{"a":1,"\\u0061":2}}',
        ]
        for index, fixture in enumerate(fixtures):
            with self.subTest(fixture=fixture):
                path = self.directory / f"Duplicate{index}.xcstrings"
                path.write_text(fixture, encoding="utf-8")
                original = path.read_bytes()

                result = self.run_normalizer("--write", path)

                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(path.read_bytes(), original)

    def test_nonstandard_numeric_constants_are_rejected(self) -> None:
        for value in ("NaN", "Infinity", "-Infinity"):
            with self.subTest(value=value):
                path = self.directory / "Nonstandard.xcstrings"
                path.write_text(
                    '{"sourceLanguage":"en","strings":{},"version":"1.0","metadata":'
                    + value
                    + '}',
                    encoding="utf-8",
                )
                original = path.read_bytes()

                result = self.run_normalizer("--write", path)

                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(path.read_bytes(), original)

    def test_invalid_catalog_structure_is_rejected_without_writing(self) -> None:
        valid = {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
        fixtures: list[object] = [[], None, "catalog", 1]
        for field, values in {
            "sourceLanguage": [None, "", 1, []],
            "strings": [None, "", 1, []],
            "version": [None, "", 1, []],
        }.items():
            missing = valid.copy()
            del missing[field]
            fixtures.append(missing)
            for value in values:
                fixtures.append({**valid, field: value})
        for entry in (None, "translation", 1, []):
            fixtures.append({**valid, "strings": {"Hello": entry}})

        for fixture in fixtures:
            with self.subTest(fixture=fixture):
                path = self.write_catalog("Invalid.xcstrings", fixture)
                original = path.read_bytes()

                result = self.run_normalizer("--write", path)

                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(path.read_bytes(), original)

    def test_default_paths_are_anchored_to_script_repository_and_limited_to_owned_catalogs(self) -> None:
        repository = self.directory / "Repository"
        scripts = repository / "Scripts"
        scripts.mkdir(parents=True)
        script = scripts / NORMALIZER.name
        shutil.copy2(NORMALIZER, script)
        resources = repository / "Frameworks" / "Resources"
        resources.mkdir(parents=True)
        fixture = '{"version":"1.0","strings":{"Hello":{}},"sourceLanguage":"en"}'
        default_paths = [resources / "Localizable.xcstrings", resources / "InfoPlist.xcstrings"]
        untouched_paths = [
            resources / "Other.xcstrings",
            self.directory / "AgentKit" / "Localizations" / "Localizable.xcstrings",
            self.directory / "Localizable.xcstrings",
        ]
        for path in default_paths + untouched_paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(fixture, encoding="utf-8")

        self.assert_success(self.run_normalizer("--write", script=script))

        for path in default_paths:
            with self.subTest(path=path):
                self.assertEqual(
                    json.loads(path.read_text(encoding="utf-8"))["strings"]["Hello"]["extractionState"],
                    "manual",
                )
        for path in untouched_paths:
            with self.subTest(path=path):
                self.assertEqual(path.read_text(encoding="utf-8"), fixture)
        self.assert_success(self.run_normalizer("--check", script=script))


if __name__ == "__main__":
    unittest.main()
