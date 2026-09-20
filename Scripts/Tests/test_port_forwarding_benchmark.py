from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path
import socket
import sys
import threading
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from port_forwarding_benchmark_common import endpoint_measurement, summarize


def load_script(name: str):
    path = SCRIPTS / name
    spec = importlib.util.spec_from_file_location(path.stem, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


termind_benchmark = load_script("benchmark-port-forwarding.py")
external_benchmark = load_script("benchmark-external-port-forwarding.py")


class TermindArgumentsTests(unittest.TestCase):
    def test_default_and_unique_connection_counts(self) -> None:
        arguments = termind_benchmark.make_parser().parse_args(
            ["--metadata", "fixture.json", "--output", "result.json"]
        )
        self.assertEqual(arguments.termind_connections, [1])
        self.assertEqual(termind_benchmark.unique_counts([1, 64, 1, 4]), [1, 64, 4])

    def test_connection_count_accepts_boundaries(self) -> None:
        self.assertEqual(termind_benchmark.connection_count("1"), 1)
        self.assertEqual(termind_benchmark.connection_count("64"), 64)

    def test_connection_count_rejects_invalid_values(self) -> None:
        for value in ("0", "65", "not-a-number"):
            with self.subTest(value=value):
                with self.assertRaises(argparse.ArgumentTypeError):
                    termind_benchmark.connection_count(value)


class ExternalArgumentsTests(unittest.TestCase):
    def test_system_and_manual_modes_are_distinct(self) -> None:
        parser = external_benchmark.make_parser()
        system = parser.parse_args(
            ["--metadata", "fixture.json", "--output", "result.json", "system-ssh"]
        )
        manual = parser.parse_args(
            [
                "--metadata",
                "fixture.json",
                "--output",
                "result.json",
                "external",
                "--name",
                "Example",
                "--kind",
                "dynamic",
                "--port",
                "1080",
            ]
        )
        self.assertEqual(system.mode, "system-ssh")
        self.assertEqual((manual.mode, manual.kind, manual.port), ("external", "dynamic", 1080))


class WorkloadTests(unittest.TestCase):
    def test_manual_endpoint_reports_network_metrics_only(self) -> None:
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        stopped = threading.Event()

        def serve() -> None:
            while not stopped.is_set():
                try:
                    connection, _ = listener.accept()
                except OSError:
                    return
                threading.Thread(target=echo, args=(connection,), daemon=True).start()

        def echo(connection: socket.socket) -> None:
            with connection:
                while data := connection.recv(65_536):
                    connection.sendall(data)

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        try:
            record = endpoint_measurement(
                "external:Example",
                listener.getsockname()[1],
                "local",
                streams=2,
                target_port=0,
                rounds=1,
            )
        finally:
            stopped.set()
            listener.close()
        self.assertEqual(record["ssh_connections"], 1)
        self.assertEqual(record["jumps"], 0)
        self.assertNotIn("cpu_s", record)
        self.assertNotIn("forwarder_peak_rss_mib", record)
        summary = summarize([record])
        self.assertEqual(summary[0]["samples"], 1)
        self.assertNotIn("median_cpu_s", summary[0])


if __name__ == "__main__":
    unittest.main()
