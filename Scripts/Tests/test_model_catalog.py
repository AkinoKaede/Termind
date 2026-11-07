# SPDX-FileCopyrightText: 2026 Kaede Akino
# SPDX-License-Identifier: GPL-3.0-only

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "update-model-catalog.py"
SPEC = importlib.util.spec_from_file_location("model_catalog", SCRIPT)
catalog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(catalog)


def fixture():
    return {
        "openai": {
            "id": "openai",
            "models": {
                "fixture": {
                    "id": "fixture",
                    "name": "Fixture",
                    "reasoning": True,
                    "tool_call": False,
                    "structured_output": False,
                    "modalities": {"input": ["text", "image", "pdf"], "output": ["text"]},
                    "limit": {"context": 100000, "input": 90000, "output": 10000},
                    "reasoning_options": [{"type": "effort", "values": ["none", "high", "xhigh", "default"]}],
                }
            },
        }
    }


def raw(value):
    return json.dumps(value).encode()


class ModelCatalogTests(unittest.TestCase):
    def test_snapshot_preserves_all_upstream_bytes_and_fields(self):
        data = fixture()
        data["openai"]["npm"] = "@ai-sdk/openai"
        data["openai"]["models"]["fixture"]["cost"] = {"input": 2.5, "output": 15}
        data["openai"]["models"]["future"] = {"type": "future", "future_field": [1, 2]}
        source = json.dumps(data, indent=3).encode() + b"\n"
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "ModelCatalog.json"
            count, warnings = catalog.update(source, output)
            self.assertEqual(count, 2)
            self.assertEqual(output.read_bytes(), source)
            self.assertEqual(warnings["retained unrecognized type: future"], 1)

    def test_missing_fields_and_new_reasoning_options_remain_untouched(self):
        data = {"custom": {"models": {
            "minimal": {"limit": {"context": 0}},
            "budget": {"reasoning_options": [{"type": "budget_tokens", "min": 1024}]},
            "toggle": {"reasoning_options": [{"type": "toggle"}]},
            "future": {"reasoning_options": [{"type": "future", "value": "anything"}]},
        }}}
        self.assertEqual(catalog.validate(raw(data))[0], 4)

    def test_local_replay_is_byte_identical(self):
        source = raw(fixture())
        with tempfile.TemporaryDirectory() as directory:
            source_path = Path(directory) / "input.json"
            output = Path(directory) / "output.json"
            source_path.write_bytes(source)
            for _ in range(2):
                subprocess.run(
                    [sys.executable, str(SCRIPT), "--input", str(source_path), "--output", str(output)],
                    check=True, capture_output=True,
                )
                self.assertEqual(output.read_bytes(), source)

    def test_special_model_types_are_preserved_without_reclassification(self):
        data = {"custom": {"models": {
            kind: {"type": kind} for kind in sorted(catalog.SUPPORTED_TYPES)
        }}}
        source = raw(data)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "ModelCatalog.json"
            count, warnings = catalog.update(source, output)
            self.assertEqual(count, len(catalog.SUPPORTED_TYPES))
            self.assertFalse(warnings)
            self.assertEqual(json.loads(output.read_bytes()), data)

    def test_duplicate_keys_normalized_ids_and_id_mismatches_are_rejected(self):
        cases = [
            b'{"a":{"models":{"x":{},"x":{}}}}',
            raw({"a": {"models": {"X": {}, "x": {}}}}),
            raw({"a": {"models": {"x": {}, "~x": {}}}}),
            raw({"a": {"id": "b", "models": {"x": {}}}}),
            raw({"a": {"models": {"x": {"id": "y"}}}}),
        ]
        for source in cases:
            with self.subTest(source=source), self.assertRaises(ValueError):
                catalog.validate(source)

    def test_invalid_input_does_not_replace_existing_snapshot(self):
        invalid = [
            b"not JSON", b"{}", b"[]", raw({"a": {"models": {"x": {"type": "future"}}}}),
            b'{"a":{"models":{"x":{"cost":{"input":NaN}}}}}',
            b'{"a":{"models":{"x":{"cost":{"input":Infinity}}}}}',
        ]
        for field, value in (("reasoning", "yes"), ("limit", {"context": -1}),
                             ("attachment", "yes"), ("temperature", 1), ("open_weights", "false"),
                             ("limit", {"output": True}), ("modalities", {"input": "text"}),
                             ("reasoning_options", [{"type": "effort", "values": "high"}])):
            data = copy.deepcopy(fixture())
            data["openai"]["models"]["fixture"][field] = value
            invalid.append(raw(data))
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "ModelCatalog.json"
            output.write_bytes(b"existing")
            for source in invalid:
                with self.subTest(source=source), self.assertRaises(ValueError):
                    catalog.update(source, output)
                self.assertEqual(output.read_bytes(), b"existing")
            self.assertEqual(list(Path(directory).iterdir()), [output])

    def test_atomic_replacement_failure_cleans_temporary_file(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "ModelCatalog.json"
            output.write_bytes(b"existing")
            with patch.object(catalog.os, "replace", side_effect=OSError("fixture failure")):
                with self.assertRaises(OSError):
                    catalog.update(raw(fixture()), output)
            self.assertEqual(output.read_bytes(), b"existing")
            self.assertEqual(list(Path(directory).iterdir()), [output])

    def test_download_failure_preserves_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "ModelCatalog.json"
            output.write_bytes(b"existing")
            with patch.object(sys, "argv", [str(SCRIPT), "--output", str(output)]):
                with patch.object(catalog, "urlopen", side_effect=OSError("offline")):
                    self.assertEqual(catalog.main(), 1)
            self.assertEqual(output.read_bytes(), b"existing")


if __name__ == "__main__":
    unittest.main()
