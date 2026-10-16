#!/usr/bin/env python3
"""Isolated Lima/OpenSSH fixture for remote persistence and terminal context tests.

Requires a running Lima VM with nerdctl. Creates a disposable Debian container,
loopback-only SSH port and ephemeral key. Never mounts or edits a user's SSH
configuration. Stop with Ctrl-C to remove the container, keys and metadata.

Run once with --max-sessions 1 for refusal/degradation and once with
--max-sessions 8 for runtime context, draft and multi-pane acceptance.
Use --metadata /tmp/termind-tmux.json, then:
TEST_RUNNER_TERMIND_TMUX_FIXTURE=/tmp/termind-tmux.json xcodebuild \
  -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' \
  -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:TFMTests/RemoteSessionWireTests \
  -only-testing:TFMTests/TerminalContextRuntimeTests \
  -parallel-testing-enabled NO test

For TerminalActivationWireTests, use --max-sessions 8 and run both
--debian-release bookworm (tmux 3.3a) and trixie (tmux 3.5a).
TerminalActivationWindowTests additionally requires TEST_RUNNER_TERMIND_WINDOW_TESTS=1;
it opens native windows and records viewport, Ghostty, PTY and tmux sizes.

For all four backends, supply --multiplexer-binaries /path/to/linux-binaries
containing zellij, zmx and herdr for the Lima VM's architecture. The fixture
installs them only inside its disposable container and prints their versions.
Use --max-sessions 8 and TEST_RUNNER_TERMIND_MULTIPLEXER_FIXTURE with
-only-testing:TFMTests/NativeMultiplexerRuntimeTests and
-only-testing:TFMTests/RemoteMultiplexerSmokeTests. The runtime suite exercises
manual and managed attachment, unrelated clients, pane changes and reconnect.
No iproute2 is installed, so this also tests endpoint discovery without ss.
"""

import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", required=True)
    parser.add_argument("--lima", default="default")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--max-sessions", type=int, default=1)
    parser.add_argument(
        "--multiplexer-binaries", type=Path,
        help="Directory of Linux zellij, zmx and herdr binaries to install in the disposable container.")
    parser.add_argument(
        "--debian-release", choices=["bookworm", "trixie"], default="trixie",
        help="bookworm supplies tmux 3.3a; trixie supplies tmux 3.5a")
    args = parser.parse_args()
    metadata = Path(args.metadata).resolve()
    if metadata.exists():
        parser.error("Metadata already exists; choose a new path.")
    if not 0 <= args.port <= 65535:
        parser.error("Port must be between 0 and 65535.")
    if not 1 <= args.max_sessions <= 32:
        parser.error("MaxSessions must be between 1 and 32.")
    binaries = ["zellij", "zmx", "herdr"]
    if args.multiplexer_binaries is not None:
        args.multiplexer_binaries = args.multiplexer_binaries.resolve()
        for binary in binaries:
            if not (args.multiplexer_binaries / binary).is_file():
                parser.error(f"Missing multiplexer binary: {args.multiplexer_binaries / binary}")
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", args.port))
        port = reservation.getsockname()[1]
    name = "termind-tmux-" + uuid.uuid4().hex[:12]

    def nerdctl(*command, **kwargs):
        kwargs.setdefault("check", True)
        return subprocess.run(
            ["limactl", "shell", args.lima, "nerdctl", *command],
            text=True, **kwargs)

    def execute(command, **kwargs):
        return nerdctl("exec", "-i", name, "sh", "-c", command, **kwargs)

    created_metadata = False
    with tempfile.TemporaryDirectory(prefix="termind-tmux-fixture-") as directory:
        root = Path(directory)
        key = root / "client"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
        try:
            nerdctl(
                "run", "--detach", "--name", name, "--publish", f"127.0.0.1:{port}:22",
                f"debian:{args.debian_release}-slim", "sleep", "infinity", stdout=subprocess.DEVNULL)
            print("Installing OpenSSH, tmux and shells in an isolated Lima container...", flush=True)
            execute(
                "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "
                "openssh-server tmux bash zsh fish vim procps >/dev/null")
            if args.multiplexer_binaries is not None:
                with subprocess.Popen(
                    ["tar", "-C", str(args.multiplexer_binaries), "-cf", "-", *binaries],
                    stdout=subprocess.PIPE,
                ) as archive:
                    nerdctl("exec", "-i", name, "tar", "-C", "/usr/local/bin", "-xf", "-", stdin=archive.stdout)
                    if archive.wait() != 0:
                        raise RuntimeError("Unable to package multiplexer binaries.")
                execute(
                    "chmod 755 /usr/local/bin/zellij /usr/local/bin/zmx /usr/local/bin/herdr; "
                    "mkdir -p /root/.config/zellij /root/.config/herdr; "
                    "printf 'show_startup_tips false\\nshow_release_notes false\\n' "
                    "> /root/.config/zellij/config.kdl; "
                    "printf 'onboarding = false\\n' > /root/.config/herdr/config.toml; "
                    "tmux -V && zellij --version && zmx version && herdr --version")
            execute(
                "umask 077; mkdir -p /root/.ssh /run/sshd; cat > /root/.ssh/authorized_keys",
                input=key.with_suffix(".pub").read_text())
            execute("cat > /tmp/termind-sshd.conf", input=f"""Port 22
ListenAddress 0.0.0.0
HostKey /etc/ssh/ssh_host_ed25519_key
PidFile /tmp/termind-sshd.pid
AuthorizedKeysFile .ssh/authorized_keys
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
UsePAM no
MaxSessions {args.max_sessions}
AcceptEnv SHELL HOME XDG_CONFIG_HOME LC_ALL TERMIND_TMUX_SHELL
AllowTcpForwarding no
AllowAgentForwarding no
X11Forwarding no
LogLevel ERROR
""")
            host_key = root / "host.pub"
            host_key.write_text(execute(
                "cat /etc/ssh/ssh_host_ed25519_key.pub", capture_output=True).stdout)
            fingerprint = subprocess.check_output(
                ["ssh-keygen", "-lf", str(host_key), "-E", "sha256"], text=True).split()[1]
            nerdctl("exec", "--detach", name, "/usr/sbin/sshd", "-D", "-e", "-f", "/tmp/termind-sshd.conf")
            for _ in range(200):
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.1) as connection:
                        connection.settimeout(0.2)
                        if connection.recv(256).startswith(b"SSH-"):
                            break
                except OSError:
                    pass
                time.sleep(0.1)
            else:
                raise RuntimeError("Lima did not forward the fixture's SSH listener.")
            descriptor = os.open(metadata, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            created_metadata = True
            with os.fdopen(descriptor, "w") as output:
                json.dump({
                    "port": port, "hostFingerprint": fingerprint, "privateKeyPath": str(key),
                    "maxSessions": args.max_sessions
                }, output)
            print(f"Fixture ready: {metadata} (MaxSessions={args.max_sessions}, loopback port {port})", flush=True)
            while True:
                signal.pause()
        except KeyboardInterrupt:
            pass
        finally:
            nerdctl("rm", "--force", name, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if created_metadata:
                metadata.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
