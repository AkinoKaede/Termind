#!/usr/bin/env python3
"""Benchmark Termind forwarding pools with the standalone Release runner."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess

from port_forwarding_benchmark_common import environment, write_output


PROJECT = "Termind.xcodeproj"
SCHEME = "TermindPortForwardingBenchmark"
PRODUCT = "termind-port-forwarding-benchmark"


def connection_count(value: str) -> int:
    try:
        count = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("connection counts must be integers from 1 through 64") from error
    if not 1 <= count <= 64:
        raise argparse.ArgumentTypeError("connection counts must be integers from 1 through 64")
    return count


def unique_counts(values: list[int]) -> list[int]:
    return list(dict.fromkeys(values))


def xcode_arguments() -> list[str]:
    return [
        "xcodebuild",
        "-project",
        PROJECT,
        "-scheme",
        SCHEME,
        "-configuration",
        "Release",
        "ONLY_ACTIVE_ARCH=YES",
        "-destination",
        "platform=macOS",
        "-onlyUsePackageVersionsFromResolvedFile",
    ]


def build_benchmark() -> Path:
    completed = subprocess.run(xcode_arguments() + ["build"], capture_output=True, text=True)
    if completed.returncode != 0:
        raise RuntimeError(build_diagnostic(completed))
    settings_result = subprocess.run(
        xcode_arguments() + ["-showBuildSettings", "-json"], capture_output=True, text=True
    )
    if settings_result.returncode != 0:
        raise RuntimeError(build_diagnostic(settings_result))
    settings_groups = json.loads(settings_result.stdout)
    settings = next(
        (
            group["buildSettings"]
            for group in settings_groups
            if group.get("target") == "TermindPortForwardingBenchmark"
        ),
        settings_groups[0]["buildSettings"],
    )
    executable = Path(settings["TARGET_BUILD_DIR"]) / settings.get("EXECUTABLE_PATH", PRODUCT)
    if not executable.is_file():
        raise RuntimeError(f"benchmark executable was not produced at {executable}")
    return executable


def build_diagnostic(completed: subprocess.CompletedProcess[str]) -> str:
    output = completed.stdout + completed.stderr
    diagnostic = "\n".join(
        line
        for line in output.splitlines()
        if "error:" in line or "failed" in line.lower() or "undefined" in line.lower()
    )
    return diagnostic or output[-8_000:]


def run_benchmark(executable: Path, metadata: Path, maximum: int) -> list[dict[str, object]]:
    completed = subprocess.run(
        [
            str(executable),
            "--metadata",
            str(metadata),
            "--max-connections",
            str(maximum),
        ],
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or completed.stdout[-8_000:])
    records: list[dict[str, object]] = []
    for line in completed.stdout.splitlines():
        marker = "FORWARDING_METRIC "
        if marker in line:
            record = json.loads(line.split(marker, 1)[1])
            record["implementation"] = f"termind-{maximum}"
            records.append(record)
    if not records:
        raise RuntimeError("standalone benchmark completed without producing metrics")
    return records


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument(
        "--termind-connections",
        type=connection_count,
        nargs="+",
        default=[1],
        metavar="N",
        help="Termind connection limits to benchmark (1...64; default: 1)",
    )
    parser.add_argument(
        "--quick",
        action="store_true",
        help="Run one repetition; the standalone benchmark still runs its complete workload matrix",
    )
    return parser


def main() -> None:
    args = make_parser().parse_args()
    if args.repetitions < 1:
        raise SystemExit("--repetitions must be at least 1")
    metadata = json.loads(args.metadata.read_text())
    repetitions = 1 if args.quick else args.repetitions
    connection_counts = unique_counts(args.termind_connections)
    executable = build_benchmark()
    records: list[dict[str, object]] = []
    for maximum in connection_counts:
        for _ in range(repetitions):
            records.extend(run_benchmark(executable, args.metadata, maximum))
    environment_values = environment(repetitions, metadata.get("server"))
    environment_values.update(
        {
            "termindConfiguration": "Release",
            "termindConnectionLimits": connection_counts,
            "runner": PRODUCT,
        }
    )
    write_output(
        args.output,
        records,
        environment_values,
        "Termind uses one stable listener port; Remote forwarding always uses one SSH connection.",
    )


if __name__ == "__main__":
    main()
