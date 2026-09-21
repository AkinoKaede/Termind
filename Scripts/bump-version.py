#!/usr/bin/env python3
"""Bump Termind's marketing version and build numbers in the Xcode project."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import sys
import tempfile


DEFAULT_PROJECT = Path(__file__).resolve().parents[1] / "Termind.xcodeproj" / "project.pbxproj"


@dataclass(frozen=True)
class Scope:
    name: str
    configuration_list_comment: str


SCOPES = (
    Scope("Project", 'Build configuration list for PBXProject "Termind"'),
    Scope("TFM", 'Build configuration list for PBXNativeTarget "TFM"'),
    Scope("TFI", 'Build configuration list for PBXNativeTarget "TFI"'),
    Scope("Widgets", 'Build configuration list for PBXNativeTarget "TermindWidgets"'),
)


@dataclass(frozen=True)
class VersionState:
    marketing_version: str
    build: int


class ProjectFormatError(RuntimeError):
    pass


def _object(text: str, object_id: str) -> tuple[int, int, str]:
    pattern = re.compile(
        rf"(?ms)^\t\t{re.escape(object_id)} /\*.*?\*/ = \{{\n.*?^\t\t\}};$"
    )
    match = pattern.search(text)
    if match is None:
        raise ProjectFormatError(f"Could not find Xcode project object {object_id}")
    return match.start(), match.end(), match.group(0)


def _configuration_ids(text: str, scope: Scope) -> list[str]:
    header = re.search(
        rf'^\t\t([A-Za-z0-9]+) /\* {re.escape(scope.configuration_list_comment)} \*/ = \{{$',
        text,
        re.MULTILINE,
    )
    if header is None:
        raise ProjectFormatError(f"Could not find configuration list for {scope.name}")

    _, _, configuration_list = _object(text, header.group(1))
    ids = re.findall(
        r"^\t\t\t\t([A-Za-z0-9]+) /\* (?:Debug|Release) \*/,$",
        configuration_list,
        re.MULTILINE,
    )
    if len(ids) != 2:
        raise ProjectFormatError(
            f"Expected Debug and Release configurations for {scope.name}, found {len(ids)}"
        )
    return ids


def _setting(configuration: str, name: str) -> str:
    match = re.search(
        rf"^\t\t\t\t{re.escape(name)} = ([^;]+);$", configuration, re.MULTILINE
    )
    if match is None:
        raise ProjectFormatError(f"Could not find {name} in a build configuration")
    return match.group(1)


def read_state(text: str, scope: Scope) -> VersionState:
    states: list[VersionState] = []
    for configuration_id in _configuration_ids(text, scope):
        _, _, configuration = _object(text, configuration_id)
        marketing_version = _setting(configuration, "MARKETING_VERSION")
        build_value = _setting(configuration, "CURRENT_PROJECT_VERSION")
        if not build_value.isdigit():
            raise ProjectFormatError(
                f"{scope.name} has a non-integer CURRENT_PROJECT_VERSION: {build_value}"
            )
        states.append(VersionState(marketing_version, int(build_value)))

    if states[0] != states[1]:
        raise ProjectFormatError(
            f"{scope.name} Debug and Release versions do not match: {states[0]} vs {states[1]}"
        )
    return states[0]


def _replace_setting(configuration: str, name: str, value: str) -> str:
    pattern = re.compile(
        rf"^(\t\t\t\t{re.escape(name)} = )[^;]+(;)$", re.MULTILINE
    )
    updated, count = pattern.subn(rf"\g<1>{value}\g<2>", configuration)
    if count != 1:
        raise ProjectFormatError(f"Expected one {name} setting, replaced {count}")
    return updated


def _update_scope(text: str, scope: Scope, state: VersionState) -> str:
    spans = [_object(text, configuration_id) for configuration_id in _configuration_ids(text, scope)]
    for start, end, configuration in sorted(spans, reverse=True):
        updated = _replace_setting(configuration, "MARKETING_VERSION", state.marketing_version)
        updated = _replace_setting(updated, "CURRENT_PROJECT_VERSION", str(state.build))
        text = text[:start] + updated + text[end:]
    return text


def parse_version(value: str) -> tuple[int, int, int]:
    if not re.fullmatch(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)", value):
        raise ValueError(f"Version must contain three numeric components, for example 1.11.0: {value}")
    major, minor, patch = (int(component) for component in value.split("."))
    return major, minor, patch


def next_version(current: str, requested: str) -> str:
    major, minor, patch = parse_version(current)
    if requested == "major":
        return f"{major + 1}.0.0"
    if requested == "minor":
        return f"{major}.{minor + 1}.0"
    if requested == "patch":
        return f"{major}.{minor}.{patch + 1}"
    parse_version(requested)
    return requested


def bump_project(
    project: Path, requested: str, *, write: bool = True
) -> tuple[dict[str, VersionState], dict[str, VersionState]]:
    original = project.read_text(encoding="utf-8")
    before = {scope.name: read_state(original, scope) for scope in SCOPES}

    if requested == "build":
        marketing_versions = {
            name: before[name].marketing_version for name in ("Project", "TFM", "TFI")
        }
    else:
        marketing_version = next_version(before["TFI"].marketing_version, requested)
        marketing_versions = {
            name: marketing_version for name in ("Project", "TFM", "TFI")
        }

    after = {
        "Project": VersionState(marketing_versions["Project"], before["Project"].build + 1),
        "TFM": VersionState(marketing_versions["TFM"], before["TFM"].build + 1),
        "TFI": VersionState(marketing_versions["TFI"], before["TFI"].build + 1),
    }
    after["Widgets"] = after["TFI"]

    updated = original
    for scope in SCOPES:
        updated = _update_scope(updated, scope, after[scope.name])

    for scope in SCOPES:
        actual = read_state(updated, scope)
        if actual != after[scope.name]:
            raise ProjectFormatError(f"Failed to verify updated {scope.name} version")

    if write:
        mode = project.stat().st_mode
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=project.parent, delete=False
        ) as temporary:
            temporary.write(updated)
            temporary_path = Path(temporary.name)
        temporary_path.chmod(mode)
        temporary_path.replace(project)

    return before, after


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Update Termind versions, increment the Project/TFM/TFI build numbers, "
            "and keep Widgets identical to TFI."
        )
    )
    parser.add_argument(
        "version",
        nargs="?",
        default="patch",
        help=(
            "build (build numbers only), major, minor, patch (default), "
            "or an explicit version such as 1.11.0"
        ),
    )
    parser.add_argument(
        "--project",
        type=Path,
        default=DEFAULT_PROJECT,
        help="path to project.pbxproj (defaults to this repository)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="show the resulting versions without modifying the project",
    )
    return parser


def main() -> int:
    arguments = make_parser().parse_args()
    try:
        before, after = bump_project(
            arguments.project.resolve(), arguments.version, write=not arguments.dry_run
        )
    except (OSError, ProjectFormatError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    action = "Would update" if arguments.dry_run else "Updated"
    print(f"{action} {arguments.project.resolve()}:")
    for scope in SCOPES:
        old = before[scope.name]
        new = after[scope.name]
        print(
            f"  {scope.name}: {old.marketing_version} ({old.build})"
            f" -> {new.marketing_version} ({new.build})"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
