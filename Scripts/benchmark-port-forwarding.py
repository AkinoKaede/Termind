#!/usr/bin/env python3
"""Compare Termind forwarding pools with macOS /usr/bin/ssh on one fixture.

The OpenSSH four-process baseline listens on four distinct ports and the client
round-robins streams. It measures a raw multi-transport ceiling; unlike Termind,
it does not provide one stable local port.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import platform
import resource
import socket
import statistics
import subprocess
import tempfile
import time


def percentile(values: list[float], fraction: float = 0.95) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int((len(ordered) - 1) * fraction))]


def reserve_port() -> int:
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        return reservation.getsockname()[1]


def wait_for_port(port: int, processes: list[subprocess.Popen[bytes]]) -> None:
    for _ in range(400):
        if any(process.poll() is not None for process in processes):
            raise RuntimeError("system ssh exited before its forwarding listener became ready")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.05):
                return
        except OSError:
            time.sleep(0.01)
    raise TimeoutError(f"forwarding listener {port} did not become ready")


def socks_connect(stream: socket.socket, target_port: int) -> None:
    stream.sendall(b"\x05\x01\x00")
    if stream.recv(2) != b"\x05\x00":
        raise RuntimeError("SOCKS greeting failed")
    stream.sendall(b"\x05\x01\x00\x01\x7f\x00\x00\x01" + target_port.to_bytes(2, "big"))
    reply = stream.recv(10)
    if len(reply) != 10 or reply[1] != 0:
        raise RuntimeError("SOCKS connect failed")


def exchange(port: int, kind: str, target_port: int, rounds: int, seed: int) -> dict[str, object]:
    began = time.perf_counter()
    stream = socket.create_connection(("127.0.0.1", port), timeout=20)
    stream.settimeout(20)
    if kind == "dynamic":
        socks_connect(stream, target_port)
    ready = time.perf_counter() - began
    payload = bytes([seed % 251]) * 65_536
    latencies: list[float] = []
    try:
        for _ in range(rounds):
            request = time.perf_counter()
            stream.sendall(payload)
            received = bytearray()
            while len(received) < len(payload):
                block = stream.recv(len(payload) - len(received))
                if not block:
                    raise EOFError("forwarding stream closed early")
                received.extend(block)
            if received != payload:
                raise RuntimeError("forwarding payload changed")
            latencies.append(time.perf_counter() - request)
    finally:
        stream.close()
    return {"ready": ready, "latencies": latencies, "bytes": len(payload) * rounds}


def ssh_command(
    metadata: dict[str, object], key_path: Path, kind: str, local_port: int, jumps: int
) -> list[str]:
    user = str(metadata["username"])
    ssh_port = int(metadata["port"])
    echo_port = int(metadata["echoPort"])
    command = [
        "/usr/bin/ssh", "-N", "-p", str(ssh_port), "-i", str(key_path),
        "-o", "BatchMode=yes", "-o", "Compression=no", "-o", "ExitOnForwardFailure=yes",
        "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
    ]
    if jumps:
        jump = f"{user}@127.0.0.1:{ssh_port}"
        command += ["-J", ",".join([jump] * jumps)]
    if kind == "local":
        command += ["-L", f"127.0.0.1:{local_port}:127.0.0.1:{echo_port}"]
    elif kind == "dynamic":
        command += ["-D", f"127.0.0.1:{local_port}"]
    else:
        command += ["-R", f"127.0.0.1:{local_port}:127.0.0.1:{echo_port}"]
    command.append(f"{user}@127.0.0.1")
    return command


def system_measurement(
    metadata: dict[str, object], key_path: Path, kind: str, streams: int,
    jumps: int, connections: int, rounds: int
) -> dict[str, object]:
    if kind == "remote":
        connections = 1
    ports = [reserve_port() for _ in range(connections)]
    before_self = resource.getrusage(resource.RUSAGE_SELF)
    before_children = resource.getrusage(resource.RUSAGE_CHILDREN)
    processes = [
        subprocess.Popen(
            ssh_command(metadata, key_path, kind, port, jumps),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for port in ports
    ]
    try:
        for port in ports:
            wait_for_port(port, processes)
        began = time.perf_counter()
        with concurrent.futures.ThreadPoolExecutor(max_workers=streams) as executor:
            results = list(
                executor.map(
                    lambda index: exchange(
                        ports[index % len(ports)], kind, int(metadata["echoPort"]), rounds, index),
                    range(streams),
                )
            )
        elapsed = time.perf_counter() - began
        rss_kib = sum(
            int(
                subprocess.check_output(
                    ["/bin/ps", "-o", "rss=", "-p", str(process.pid)], text=True
                ).strip()
                or 0
            )
            for process in processes
            if process.poll() is None
        )
    finally:
        for process in processes:
            process.terminate()
        for process in processes:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    after_self = resource.getrusage(resource.RUSAGE_SELF)
    after_children = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = (
        after_self.ru_utime - before_self.ru_utime + after_self.ru_stime - before_self.ru_stime
        + after_children.ru_utime - before_children.ru_utime
        + after_children.ru_stime - before_children.ru_stime
    )
    total_bytes = sum(int(result["bytes"]) for result in results)
    latencies = [latency for result in results for latency in result["latencies"]]
    return {
        "implementation": f"system-ssh-{connections}", "kind": kind, "streams": streams,
        "jumps": jumps, "ssh_connections": connections, "rounds": rounds,
        "payload_bytes_per_direction": total_bytes, "elapsed_s": elapsed,
        "payload_mib_s_per_direction": total_bytes / 1_048_576 / elapsed,
        "ready_p95_ms": percentile([float(result["ready"]) for result in results]) * 1_000,
        "request_p95_ms": percentile(latencies) * 1_000, "cpu_s": cpu,
        "forwarder_peak_rss_mib": rss_kib / 1_024,
    }


def termind_measurements(
    metadata_path: Path, maximum: int, without_building: bool
) -> list[dict[str, object]]:
    environment = os.environ.copy()
    environment.update(
        TEST_RUNNER_TERMIND_SSH_FIXTURE=str(metadata_path),
        TEST_RUNNER_TERMIND_FORWARDING_BENCHMARK="1",
        TEST_RUNNER_TERMIND_FORWARDING_MAX_CONNECTIONS=str(maximum),
    )
    excluded = [
        path.name
        for root in (Path("FrameworkTests"), Path("TFMTests"))
        for path in root.glob("*.swift")
        if path.name != "SSHForwardingWireTests.swift"
    ]
    command = [
        "xcodebuild", "-project", "Termind.xcodeproj", "-scheme", "TFM",
        "-configuration", "Release", "ENABLE_TESTABILITY=YES", "ONLY_ACTIVE_ARCH=YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) TERMIND_FORWARDING_BENCHMARK",
        "EXCLUDED_SOURCE_FILE_NAMES=$(inherited) " + " ".join(excluded),
        "-destination", "platform=macOS", "-onlyUsePackageVersionsFromResolvedFile",
        "-only-testing:TFMTests/SSHForwardingWireTests",
        "test-without-building" if without_building else "test",
    ]
    completed = subprocess.run(command, env=environment, capture_output=True, text=True)
    if completed.returncode != 0:
        diagnostic = "\n".join(
            line for line in (completed.stdout + completed.stderr).splitlines()
            if "error:" in line or "failed" in line.lower() or "undefined" in line.lower()
            or "symbol" in line.lower()
        )
        raise RuntimeError(diagnostic or completed.stdout[-8_000:] + completed.stderr[-8_000:])
    records: list[dict[str, object]] = []
    for line in completed.stdout.splitlines():
        marker = "FORWARDING_METRIC "
        if marker in line:
            record = json.loads(line.split(marker, 1)[1])
            record["implementation"] = f"termind-{maximum}"
            records.append(record)
    return records


def summarize(records: list[dict[str, object]]) -> list[dict[str, object]]:
    groups: dict[tuple[object, ...], list[dict[str, object]]] = {}
    identity = ("implementation", "kind", "streams", "jumps", "workload", "ssh_connections")
    for record in records:
        key = tuple(record.get(field, "request_response") for field in identity)
        groups.setdefault(key, []).append(record)
    metrics = (
        "payload_mib_s_per_direction", "ready_p95_ms", "request_p95_ms", "small_request_p95_ms",
        "cpu_s", "process_peak_rss_mib", "forwarder_peak_rss_mib",
    )
    summaries: list[dict[str, object]] = []
    for key, samples in groups.items():
        summary = dict(zip(identity, key))
        summary["samples"] = len(samples)
        for metric in metrics:
            values = [float(sample[metric]) for sample in samples if metric in sample]
            if values:
                summary[f"median_{metric}"] = statistics.median(values)
        summaries.append(summary)
    return summaries


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--rounds", type=int, default=128)
    parser.add_argument(
        "--quick", action="store_true",
        help="Use one repetition and reduce the system SSH matrix; the Termind wire suite remains complete")
    parser.add_argument("--skip-termind", action="store_true")
    parser.add_argument("--skip-system", action="store_true")
    args = parser.parse_args()
    metadata = json.loads(args.metadata.read_text())
    repetitions = 1 if args.quick else args.repetitions
    streams = [1, 16] if args.quick else [1, 16, 64]
    jumps = [0] if args.quick else [0, 1, 2]
    records: list[dict[str, object]] = []

    with tempfile.TemporaryDirectory(prefix="termind-forwarding-benchmark-") as directory:
        key_path = Path(directory) / "client"
        key_path.write_text(str(metadata["privateKey"]))
        key_path.chmod(0o600)
        if not args.skip_system:
            for _ in range(repetitions):
                for kind in ("local", "dynamic", "remote"):
                    for jump_count in jumps:
                        for stream_count in streams:
                            for connections in ([1, 4] if kind != "remote" else [1]):
                                records.append(
                                    system_measurement(
                                        metadata, key_path, kind, stream_count,
                                        jump_count, connections, args.rounds))
    if not args.skip_termind:
        for maximum in (1, 4):
            for repetition in range(repetitions):
                records.extend(termind_measurements(args.metadata, maximum, repetition > 0 or maximum > 1))

    payload = {
        "environment": {
            "macOS": platform.mac_ver()[0],
            "machine": platform.machine(),
            "systemSSH": subprocess.check_output(["/usr/bin/ssh", "-V"], stderr=subprocess.STDOUT, text=True).strip(),
            "server": metadata.get("server", "unknown"),
            "repetitions": repetitions,
            "termindConfiguration": "Release",
        },
        "note": "system-ssh-4 uses four distinct listener ports; Termind retains one listener port.",
        "records": records,
        "medians": summarize(records),
    }
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
