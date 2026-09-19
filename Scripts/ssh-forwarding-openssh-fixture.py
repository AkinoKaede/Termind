#!/usr/bin/env python3
"""Temporary loopback-only OpenSSH forwarding fixture. Requires local sshd.

No system SSH configuration or authorized_keys files are changed. Only forwarding
is allowed; MaxSessions=0 disables shell, command and subsystem sessions.
Pass --metadata to TERMIND_SSH_FIXTURE in SSHForwardingWireTests.
"""

import argparse
import getpass
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import threading
import time


def echo_connection(connection):
    with connection:
        try:
            while data := connection.recv(65536):
                connection.sendall(data)
        except OSError:
            pass


def echo_server(listener):
    while True:
        try:
            connection, _ = listener.accept()
        except OSError:
            return
        threading.Thread(target=echo_connection, args=(connection,), daemon=True).start()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", required=True)
    args = parser.parse_args()
    metadata = Path(args.metadata)
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    with tempfile.TemporaryDirectory(prefix="termind-openssh-") as directory, socket.socket() as echo:
        root = Path(directory)
        for name in ("host", "client"):
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)], check=True)
        authorized = root / "authorized_keys"
        authorized.write_text((root / "client.pub").read_text())
        authorized.chmod(0o600)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        echo.bind(("127.0.0.1", 0))
        echo.listen(128)
        echo_port = echo.getsockname()[1]
        threading.Thread(target=echo_server, args=(echo,), daemon=True).start()
        config = root / "sshd_config"
        config.write_text(f"""ListenAddress 127.0.0.1
Port {port}
HostKey {root / 'host'}
PidFile {root / 'pid'}
AuthorizedKeysFile {authorized}
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers {getpass.getuser()}
AllowTcpForwarding yes
PermitOpen 127.0.0.1:{port} 127.0.0.1:{echo_port}
PermitListen 127.0.0.1:*
GatewayPorts no
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
MaxSessions 0
LogLevel ERROR
""")
        server = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(config)], start_new_session=True)
        created_metadata = False
        try:
            for _ in range(100):
                if server.poll() is not None:
                    raise RuntimeError("sshd exited before becoming ready; see its diagnostic above")
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                        break
                except OSError:
                    time.sleep(0.05)
            else:
                raise RuntimeError("sshd did not become ready")
            descriptor = os.open(metadata, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            created_metadata = True
            with os.fdopen(descriptor, "w") as output:
                json.dump({"port": port, "echoPort": echo_port, "server": "openssh",
                           "username": getpass.getuser(), "privateKey": (root / "client").read_text()}, output)
            print(f"OpenSSH forwarding fixture listening on 127.0.0.1:{port}", flush=True)
            server.wait()
        except KeyboardInterrupt:
            pass
        finally:
            if server.poll() is None:
                os.killpg(server.pid, signal.SIGTERM)
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(server.pid, signal.SIGKILL)
                server.wait()
            if created_metadata:
                metadata.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
