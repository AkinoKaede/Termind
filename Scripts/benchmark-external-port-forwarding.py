#!/usr/bin/env python3
"""Benchmark single-connection system SSH or a manually configured forwarder."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import resource
import subprocess
import tempfile

from port_forwarding_benchmark_common import (
    endpoint_measurement,
    environment,
    reserve_port,
    wait_for_port,
    write_output,
)


def ssh_command(
    metadata: dict[str, object], key_path: Path, kind: str, listener_port: int
) -> list[str]:
    user = str(metadata["username"])
    ssh_port = int(metadata["port"])
    echo_port = int(metadata["echoPort"])
    command = [
        "/usr/bin/ssh",
        "-N",
        "-p",
        str(ssh_port),
        "-i",
        str(key_path),
        "-o",
        "BatchMode=yes",
        "-o",
        "Compression=no",
        "-o",
        "ExitOnForwardFailure=yes",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
    ]
    if kind == "local":
        command += ["-L", f"127.0.0.1:{listener_port}:127.0.0.1:{echo_port}"]
    elif kind == "dynamic":
        command += ["-D", f"127.0.0.1:{listener_port}"]
    else:
        command += ["-R", f"127.0.0.1:{listener_port}:127.0.0.1:{echo_port}"]
    command.append(f"{user}@127.0.0.1")
    return command


def system_measurement(
    metadata: dict[str, object],
    key_path: Path,
    kind: str,
    streams: int,
    rounds: int,
) -> dict[str, object]:
    listener_port = reserve_port()
    before_self = resource.getrusage(resource.RUSAGE_SELF)
    before_children = resource.getrusage(resource.RUSAGE_CHILDREN)
    process = subprocess.Popen(
        ssh_command(metadata, key_path, kind, listener_port),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        wait_for_port(listener_port, process_failed=lambda: process.poll() is not None)
        record = endpoint_measurement(
            "system-ssh-1",
            listener_port,
            kind,
            streams,
            int(metadata["echoPort"]),
            rounds,
        )
        rss_text = subprocess.check_output(
            ["/bin/ps", "-o", "rss=", "-p", str(process.pid)], text=True
        ).strip()
        record["forwarder_peak_rss_mib"] = int(rss_text or 0) / 1_024
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    after_self = resource.getrusage(resource.RUSAGE_SELF)
    after_children = resource.getrusage(resource.RUSAGE_CHILDREN)
    record["cpu_s"] = (
        after_self.ru_utime
        - before_self.ru_utime
        + after_self.ru_stime
        - before_self.ru_stime
        + after_children.ru_utime
        - before_children.ru_utime
        + after_children.ru_stime
        - before_children.ru_stime
    )
    return record


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--rounds", type=int, default=128)
    parser.add_argument(
        "--quick",
        action="store_true",
        help="Use one repetition and test 1 and 16 streams instead of 1, 16 and 64",
    )
    modes = parser.add_subparsers(dest="mode", required=True)
    modes.add_parser("system-ssh", help="Automatically configure macOS /usr/bin/ssh")
    external = modes.add_parser("external", help="Measure an already running forwarding listener")
    external.add_argument("--name", required=True)
    external.add_argument("--kind", choices=("local", "dynamic", "remote"), required=True)
    external.add_argument("--port", type=int, required=True)
    return parser


def main() -> None:
    args = make_parser().parse_args()
    if args.repetitions < 1:
        raise SystemExit("--repetitions must be at least 1")
    if args.rounds < 1:
        raise SystemExit("--rounds must be at least 1")
    metadata = json.loads(args.metadata.read_text())
    repetitions = 1 if args.quick else args.repetitions
    streams = [1, 16] if args.quick else [1, 16, 64]
    records: list[dict[str, object]] = []
    environment_values = environment(repetitions, metadata.get("server"))

    if args.mode == "system-ssh":
        with tempfile.TemporaryDirectory(prefix="termind-system-ssh-benchmark-") as directory:
            key_path = Path(directory) / "client"
            descriptor = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w") as key_file:
                key_file.write(str(metadata["privateKey"]))
            for _ in range(repetitions):
                for kind in ("local", "dynamic", "remote"):
                    for stream_count in streams:
                        records.append(
                            system_measurement(metadata, key_path, kind, stream_count, args.rounds)
                        )
        environment_values["systemSSH"] = subprocess.check_output(
            ["/usr/bin/ssh", "-V"], stderr=subprocess.STDOUT, text=True
        ).strip()
        note = "macOS system SSH uses one process, one listener and one direct SSH connection per measurement."
    else:
        if not 1 <= args.port <= 65_535:
            raise SystemExit("--port must be from 1 through 65535")
        wait_for_port(args.port)
        implementation = f"external:{args.name}"
        for _ in range(repetitions):
            for stream_count in streams:
                records.append(
                    endpoint_measurement(
                        implementation,
                        args.port,
                        args.kind,
                        stream_count,
                        int(metadata["echoPort"]),
                        args.rounds,
                    )
                )
        environment_values.update(
            {
                "externalName": args.name,
                "externalKind": args.kind,
                "externalPort": args.port,
            }
        )
        note = (
            "The external listener is treated as one direct SSH connection. CPU, RSS and application startup "
            "time are not measured."
        )

    write_output(args.output, records, environment_values, note)


if __name__ == "__main__":
    main()
