#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Kaede Akino
# SPDX-License-Identifier: GPL-3.0-only

"""Ephemeral loopback OpenSSH fixture for SSHAgentForwardingWireTests.

Creates fresh keys, three unprivileged sshd instances (destination, second hop,
and forwarding-denied destination), and a bare Git repository. Never reads or
changes the user's SSH configuration or authorized_keys. Requires OpenSSH/git.
Pass --metadata PATH to TEST_RUNNER_TERMIND_AGENT_FORWARDING_FIXTURE for Xcode.
"""
import argparse
import base64
import getpass
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL)


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", required=True)
    args = parser.parse_args()
    metadata = Path(args.metadata)
    processes = []
    logs = []
    stopped = False

    def stop(*_):
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    with tempfile.TemporaryDirectory(prefix="termind-agent-wire-") as directory:
        root = Path(directory)
        try:
            for name in ("server", "login", "forwarded"):
                run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name))
            (root / "authorized_keys").write_text((root / "login.pub").read_text() + (root / "forwarded.pub").read_text())
            run("git", "init", "--bare", "--quiet", str(root / "fixture.git"))
            shell = root / "fixture-shell"
            shell.write_text('#!/bin/sh\nif [ -n "$SSH_ORIGINAL_COMMAND" ]; then exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"; else exec /bin/sh -i; fi\n')
            shell.chmod(0o700)
            ports = [port() for _ in range(3)]
            for index, listen_port in enumerate(ports):
                config = root / f"sshd-{index}.conf"
                config.write_text(f"""Port {listen_port}
ListenAddress 127.0.0.1
HostKey {root / 'server'}
PidFile {root / f'sshd-{index}.pid'}
AuthorizedKeysFile {root / 'authorized_keys'}
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowAgentForwarding {'no' if index == 2 else 'yes'}
AllowTcpForwarding yes
ForceCommand {shell}
LogLevel VERBOSE
""")
                log = open(root / f"sshd-{index}.log", "w+")
                logs.append(log)
                processes.append(subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(config)], stderr=log))
            time.sleep(1)
            for process, log in zip(processes, logs):
                if process.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(log.read())
            blob = base64.b64decode((root / "server.pub").read_text().split()[1])
            values = {
                "port": ports[0], "targetPort": ports[1], "deniedPort": ports[2],
                "username": getpass.getuser(), "loginPrivateKey": (root / "login").read_text(),
                "forwardedPrivateKey": (root / "forwarded").read_text(),
                "forwardedPublicKey": (root / "forwarded.pub").read_text(),
                "fingerprint": "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("="),
                "gitPath": str(root / "fixture.git"),
            }
            descriptor = os.open(metadata, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w") as file:
                json.dump(values, file)
            print(f"Agent forwarding fixture ready: {metadata}", flush=True)
            while not stopped:
                if any(process.poll() is not None for process in processes):
                    raise RuntimeError("sshd exited unexpectedly")
                time.sleep(0.2)
        finally:
            metadata.unlink(missing_ok=True)
            for process in processes:
                process.terminate()
            for process in processes:
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            for log in logs:
                log.close()


if __name__ == "__main__":
    main()
