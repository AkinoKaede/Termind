#!/usr/bin/env python3
"""Check Chinese and Japanese catalog coverage, format arguments, and spacing."""

from __future__ import annotations

import argparse
from collections import Counter
import importlib.util
from pathlib import Path
import re
import sys


SCRIPTS = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("catalog_normalizer", SCRIPTS / "normalize-string-catalogs.py")
assert SPEC is not None and SPEC.loader is not None
CATALOGS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CATALOGS)

JAPANESE = r"\u3005\u3006\u3041-\u3096\u30A1-\u30FA\u30FC\u3400-\u4DBF\u4E00-\u9FFF"
LATIN = r"A-Za-z0-9%@`"
SPACE = r"[ \t\u00A0\u3000]+"
MIXED_SPACING = re.compile(rf"[{JAPANESE}]{SPACE}[{LATIN}]|[{LATIN}]{SPACE}[{JAPANESE}]")
FORMAT = re.compile(r"%(?:(?P<position>[1-9][0-9]*)\$)?[-+ #0]*[0-9]*(?:\.[0-9]+)?(?P<type>hh[diouxX]|h[diouxX]|ll[diouxX]|l[diouxXfFeEgG]|z[diouxX]|[diouxXfFeEgGaAcCsSp@%])")


def units(value: dict):
    if "stringUnit" in value:
        yield value["stringUnit"]
    for key, child in value.items():
        if key != "stringUnit" and isinstance(child, dict):
            yield from units(child)


def arguments(value: str) -> Counter:
    """Positions matter: translating word order must not exchange argument types."""
    result = Counter()
    next_position = 1
    for match in FORMAT.finditer(value):
        kind = match["type"]
        if kind == "%":
            result[(0, "%")] += 1
            continue
        position = int(match["position"]) if match["position"] else next_position
        next_position += match["position"] is None
        result[(position, kind)] += 1
    return result


def problems(catalog: dict, languages=("zh-Hans", "zh-Hant", "ja")) -> list[str]:
    return [problem for language in languages for problem in language_problems(catalog, language)]


def language_problems(catalog: dict, language: str) -> list[str]:
    failures = []
    for key, entry in catalog["strings"].items():
        if entry.get("shouldTranslate") is False:
            continue
        localizations = entry.get("localizations", {})
        localization = localizations.get(language, {})
        translated = list(units(localization))
        if not translated:
            failures.append(f"{key!r}: missing {language} translation")
            continue
        english = localizations.get(catalog["sourceLanguage"], {})
        source_unit = english.get("stringUnit") or english.get("variations", {}).get("plural", {}).get(
            "other", {}
        ).get("stringUnit", {"value": key})
        expected = arguments(source_unit["value"])
        if "plural" in english.get("variations", {}):
            if set(localization.get("variations", {}).get("plural", {})) != {"other"}:
                failures.append(f"{key!r}: {language} plural rules must contain only 'other'")
        for unit in translated:
            value = unit.get("value")
            if unit.get("state") != "translated" or not isinstance(value, str) or (key and not value):
                failures.append(f"{key!r}: unfinished {language} translation")
                continue
            if arguments(value) != expected:
                failures.append(f"{key!r}: {language} format arguments differ: {value!r}")
            # Key-card subtitles intentionally separate the label and value.
            spacing_value = value
            if language == "ja":
                if key == "Type %@":
                    spacing_value = re.sub(r"^種類 (?=%(?:1\$)?@)", "種類", value)
                invalid_spacing = MIXED_SPACING.search(spacing_value)
            else:
                if key == "Type %@":
                    spacing_value = re.sub(r"^(类型|類型) (?=%@)", r"\1", value)
                han = r"\u3400-\u4DBF\u4E00-\u9FFF"
                invalid_spacing = re.search(rf"[{han}]", spacing_value) and (
                    re.search(rf"[{han}]{SPACE}[{LATIN}]|[{LATIN}]{SPACE}[{han}]", spacing_value)
                    or re.search(r"[ \t]+[—·→：，。！？；、/:]|[—·→：，。！？；、/:][ \t]+", spacing_value)
                    or re.search(rf"[{han}][,.!?;]|[,.!?;][{han}]", spacing_value)
                )
            if invalid_spacing:
                failures.append(f"{key!r}: invalid {language} spacing: {value!r}")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalogs", nargs="*", type=Path)
    args = parser.parse_args()
    failed = False
    for path in args.catalogs or CATALOGS.DEFAULT_CATALOGS:
        try:
            original = path.read_bytes()
            failures = problems(CATALOGS.load_catalog(original))
            if CATALOGS.normalize(original) != original:
                failures.append("expected manual extraction state and canonical Xcode formatting; "
                                "run Scripts/normalize-string-catalogs.py --write")
        except (OSError, ValueError) as error:
            print(f"{path}: {error}", file=sys.stderr)
            failed = True
            continue
        for failure in failures:
            print(f"{path}: {failure}", file=sys.stderr)
        failed |= bool(failures)
    if not failed:
        print("zh-Hans, zh-Hant, and ja coverage, format arguments, spacing, and catalog checks passed.")
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
