#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Kaede Akino
# SPDX-License-Identifier: GPL-3.0-only

"""Keep shared, manually maintained string catalogs stable in Xcode and Git.

Only extractionState and JSON serialization change. In particular, a stale entry
is retained with all of its translations: one target's extraction cannot prove
that a string in a catalog shared by multiple targets is unused.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


RESOURCES = Path(__file__).resolve().parents[1] / "Frameworks" / "Resources"
DEFAULT_CATALOGS = (
    RESOURCES / "Localizable.xcstrings",
    RESOURCES / "InfoPlist.xcstrings",
)


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key!r}")
        result[key] = value
    return result


def reject_constant(value: str) -> None:
    raise ValueError(f"invalid JSON constant: {value}")


def load_catalog(contents: bytes) -> dict:
    catalog = json.loads(
        contents.decode("utf-8"),
        object_pairs_hook=unique_object,
        parse_constant=reject_constant,
    )
    if not isinstance(catalog, dict):
        raise ValueError("catalog must be a JSON object")
    for field in ("sourceLanguage", "version"):
        if not isinstance(catalog.get(field), str) or not catalog[field]:
            raise ValueError(f"{field} must be a nonempty string")
    if not isinstance(catalog.get("strings"), dict):
        raise ValueError("strings must be a JSON object")
    for key, entry in catalog["strings"].items():
        if not isinstance(entry, dict):
            raise ValueError(f"string entry {key!r} must be a JSON object")
    return catalog


def serialize(value: object, depth: int = 0) -> str:
    """Match xcstringstool's Unicode ordering, whitespace and unescaped slashes."""
    indent = "  " * depth
    child_indent = indent + "  "
    if isinstance(value, dict):
        members = [
            f"{child_indent}{json.dumps(key, ensure_ascii=False)} : {serialize(value[key], depth + 1)}"
            for key in sorted(value)
        ]
        return "{\n" + ",\n".join(members) + "\n" + indent + "}"
    if isinstance(value, list):
        members = [child_indent + serialize(item, depth + 1) for item in value]
        return "[\n" + ",\n".join(members) + "\n" + indent + "]"
    return json.dumps(value, ensure_ascii=False, allow_nan=False)


def normalize(contents: bytes) -> bytes:
    catalog = load_catalog(contents)
    for entry in catalog["strings"].values():
        entry["extractionState"] = "manual"
    # Xcode does not append a newline to string catalogs.
    return serialize(catalog).encode("utf-8")


def replace_catalog(path: Path, contents: bytes) -> None:
    """Replace atomically so an interrupted write cannot truncate translations."""
    mode = stat.S_IMODE(path.stat().st_mode)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(contents)
        temporary.chmod(mode)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="report drift without changing any files")
    mode.add_argument("--write", action="store_true", help="normalize extraction state and Xcode formatting")
    parser.add_argument("catalogs", nargs="*", type=Path, help="catalogs (default: Termind's two shared catalogs)")
    arguments = parser.parse_args()

    pending = []
    invalid = False
    # Validate the entire batch before writing any files. Duplicate JSON keys
    # must fail here rather than silently discarding a translation while parsing.
    for path in arguments.catalogs or DEFAULT_CATALOGS:
        try:
            original = path.read_bytes()
            normalized = normalize(original)
            if normalized != original:
                pending.append((path, normalized))
        except (OSError, ValueError) as error:
            print(f"{path}: {error}", file=sys.stderr)
            invalid = True
    if invalid:
        return 1

    if arguments.check:
        for path, _ in pending:
            print(f"{path}: expected manual extraction state and canonical Xcode formatting", file=sys.stderr)
        if pending:
            print("Run Scripts/normalize-string-catalogs.py --write [catalog ...] to normalize.", file=sys.stderr)
            return 1
        print("String catalogs use manual extraction state and canonical Xcode formatting.")
        return 0

    for path, contents in pending:
        try:
            replace_catalog(path, contents)
        except OSError as error:
            print(f"{path}: {error}", file=sys.stderr)
            return 1
        print(f"Normalized {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
