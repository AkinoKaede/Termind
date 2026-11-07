#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Kaede Akino
# SPDX-License-Identifier: GPL-3.0-only

"""Save the unmodified models.dev API response, or replay a saved response."""

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
from urllib.request import Request, urlopen


SOURCE = "https://models.dev/api.json"
DEFAULT_OUTPUT = Path(__file__).resolve().parents[1] / "Frameworks/Resources/ModelCatalog.json"
SUPPORTED_TYPES = {"chat", "embedding", "reranking", "image", "video", "speech", "transcription", "realtime", "decision"}


def object_value(value, label):
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    return value


def identifier(value, label):
    if not isinstance(value, str) or not value or value != value.strip():
        raise ValueError(f"{label} must be a nonempty, unpadded string")
    return value


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_nonfinite_number(value):
    raise ValueError(f"invalid JSON number: {value}")


def validate(raw):
    providers = object_value(
        json.loads(raw, object_pairs_hook=reject_duplicate_keys, parse_constant=reject_nonfinite_number), "catalog"
    )
    seen = set()
    warnings = Counter()
    model_count = 0
    supported_count = 0
    for provider_id, provider in providers.items():
        identifier(provider_id, "provider ID")
        provider = object_value(provider, provider_id)
        if provider.get("id", provider_id) != provider_id:
            raise ValueError(f"provider ID mismatch: {provider_id}")
        models = object_value(provider.get("models"), f"{provider_id}.models")
        for model_id, model in models.items():
            identifier(model_id, "model ID")
            model = object_value(model, f"{provider_id}/{model_id}")
            if model.get("id", model_id) != model_id:
                raise ValueError(f"model ID mismatch: {provider_id}/{model_id}")
            key = (provider_id.lower(), model_id.lower().removeprefix("~"))
            if key in seen:
                raise ValueError(f"duplicate normalized model: {provider_id}/{model_id}")
            seen.add(key)
            model_count += 1
            kind = model.get("type", "chat")
            if not isinstance(kind, str):
                raise ValueError("model type must be a string")
            if kind in SUPPORTED_TYPES:
                supported_count += 1
            else:
                warnings[f"retained unrecognized type: {kind}"] += 1
            if not isinstance(model.get("name", model_id), str):
                raise ValueError("model name must be a string")
            for field in ("reasoning", "tool_call", "structured_output", "attachment", "temperature", "open_weights"):
                value = model.get(field)
                if value is not None and not isinstance(value, bool):
                    raise ValueError(f"{field} must be a boolean")
            limits = object_value(model.get("limit", {}), "limit")
            for field in ("context", "input", "output"):
                value = limits.get(field)
                if value is not None and (type(value) is not int or value < 0):
                    raise ValueError(f"limit.{field} must be a nonnegative integer")
            modes = object_value(model.get("modalities", {}), "modalities")
            for field in ("input", "output"):
                value = modes.get(field)
                if value is not None and (
                    not isinstance(value, list) or any(not isinstance(item, str) for item in value)
                ):
                    raise ValueError(f"modalities.{field} must be a string array")
            options = model.get("reasoning_options", [])
            if not isinstance(options, list):
                raise ValueError("reasoning_options must be an array")
            for option in options:
                option = object_value(option, "reasoning option")
                if option.get("type") == "effort":
                    values = option.get("values")
                    if not isinstance(values, list) or any(not isinstance(value, str) for value in values):
                        raise ValueError("effort.values must be a string array")
    if not supported_count:
        raise ValueError("catalog contains no supported models")
    return model_count, warnings


def update(raw, output):
    model_count, warnings = validate(raw)
    # Keep the upstream bytes, including all fields AgentKit does not yet use.
    # Validation completes before the existing snapshot can be replaced.
    with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".model-catalog-", delete=False) as temporary:
        temporary_path = Path(temporary.name)
        try:
            temporary.write(raw)
            temporary.flush()
            os.fchmod(temporary.fileno(), 0o644)
            os.replace(temporary_path, output)
        finally:
            temporary_path.unlink(missing_ok=True)
    return model_count, warnings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, help="Saved models.dev API JSON; omit to download")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    try:
        if args.input:
            raw = args.input.read_bytes()
        else:
            request = Request(SOURCE, headers={"User-Agent": "Termind-Model-Catalog"})
            with urlopen(request, timeout=60) as response:
                raw = response.read()
        model_count, warnings = update(raw, args.output)
    except (OSError, ValueError) as error:
        print(f"Catalog update failed: {error}", file=sys.stderr)
        return 1
    for warning, count in sorted(warnings.items()):
        print(f"{warning}: {count}", file=sys.stderr)
    print(f"Wrote {model_count} models to {args.output} (SHA-256 {hashlib.sha256(raw).hexdigest()})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
