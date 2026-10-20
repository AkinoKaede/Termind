# SPDX-FileCopyrightText: 2026 Kaede Akino
# SPDX-License-Identifier: GPL-3.0-only

"""Shared workload and JSON helpers for port forwarding benchmarks."""

from __future__ import annotations

import concurrent.futures
import json
from pathlib import Path
import platform
import socket
import statistics
import time
from typing import Callable


def percentile(values: list[float], fraction: float = 0.95) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int((len(ordered) - 1) * fraction))]


def reserve_port() -> int:
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        return reservation.getsockname()[1]


def wait_for_port(
    port: int,
    process_failed: Callable[[], bool] | None = None,
    timeout: float = 5.0,
) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process_failed is not None and process_failed():
            raise RuntimeError("forwarding process exited before its listener became ready")
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


def endpoint_measurement(
    implementation: str,
    port: int,
    kind: str,
    streams: int,
    target_port: int,
    rounds: int,
) -> dict[str, object]:
    began = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=streams) as executor:
        results = list(
            executor.map(
                lambda index: exchange(port, kind, target_port, rounds, index),
                range(streams),
            )
        )
    elapsed = time.perf_counter() - began
    total_bytes = sum(int(result["bytes"]) for result in results)
    latencies = [latency for result in results for latency in result["latencies"]]
    return {
        "implementation": implementation,
        "kind": kind,
        "streams": streams,
        "jumps": 0,
        "workload": "request_response",
        "ssh_connections": 1,
        "rounds": rounds,
        "successful_streams": len(results),
        "payload_bytes_per_direction": total_bytes,
        "elapsed_s": elapsed,
        "payload_mib_s_per_direction": total_bytes / 1_048_576 / elapsed,
        "ready_p95_ms": percentile([float(result["ready"]) for result in results]) * 1_000,
        "request_p95_ms": percentile(latencies) * 1_000,
    }


def summarize(records: list[dict[str, object]]) -> list[dict[str, object]]:
    groups: dict[tuple[object, ...], list[dict[str, object]]] = {}
    identity = ("implementation", "kind", "streams", "jumps", "workload", "ssh_connections")
    for record in records:
        key = tuple(record.get(field, "request_response") for field in identity)
        groups.setdefault(key, []).append(record)
    metrics = (
        "payload_mib_s_per_direction",
        "ready_p95_ms",
        "request_p95_ms",
        "small_request_p95_ms",
        "cpu_s",
        "process_peak_rss_mib",
        "forwarder_peak_rss_mib",
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


def environment(repetitions: int, server: object) -> dict[str, object]:
    return {
        "macOS": platform.mac_ver()[0],
        "machine": platform.machine(),
        "server": server or "unknown",
        "repetitions": repetitions,
    }


def write_output(
    output: Path,
    records: list[dict[str, object]],
    environment_values: dict[str, object],
    note: str,
) -> None:
    payload = {
        "environment": environment_values,
        "note": note,
        "records": records,
        "medians": summarize(records),
    }
    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
