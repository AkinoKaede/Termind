#!/usr/bin/env python3
"""Disposable OpenSSH server with a software-simulated WebAuthn authenticator.

No hardware, user SSH configuration, or private keys are read. Pass --metadata
PATH as TEST_RUNNER_TERMIND_SECURITY_KEY_FIXTURE to the focused Xcode wire test.
"""
import argparse
import base64
import getpass
import hashlib
import json
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--metadata', required=True)
    args = parser.parse_args()
    stopped = False

    def stop(*_):
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    with tempfile.TemporaryDirectory(prefix='termind-security-key-') as directory:
        root = Path(directory)
        generator = root / 'generate.swift'
        generator.write_text('''import CryptoKit
import Foundation
let key = P256.Signing.PrivateKey()
let value = ["privateKey": key.rawRepresentation.base64EncodedString(), "publicKey": key.publicKey.x963Representation.base64EncodedString()]
print(String(data: try JSONEncoder().encode(value), encoding: .utf8)!)
''')
        key = json.loads(subprocess.check_output(['xcrun', 'swift', str(generator)], text=True))

        def field(value):
            return len(value).to_bytes(4, 'big') + value

        algorithm = b'sk-ecdsa-sha2-nistp256@openssh.com'
        public = field(algorithm) + field(b'nistp256') + field(base64.b64decode(key['publicKey'])) + field(b'termind.akinokaede.com')
        (root / 'authorized_keys').write_text(algorithm.decode() + ' ' + base64.b64encode(public).decode() + '\n')
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(root / 'server')], check=True)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        config = root / 'sshd.conf'
        config.write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {root / 'server'}
PidFile {root / 'sshd.pid'}
AuthorizedKeysFile {root / 'authorized_keys'}
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowTcpForwarding yes
Subsystem sftp internal-sftp
LogLevel VERBOSE
''')
        with (root / 'sshd.log').open('w+') as log:
            process = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(config)], stderr=log)
            try:
                time.sleep(1)
                if process.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(log.read())
                blob = base64.b64decode((root / 'server.pub').read_text().split()[1])
                metadata = Path(args.metadata)
                metadata.write_text(json.dumps({
                    'port': port, 'username': getpass.getuser(), 'privateKey': key['privateKey'],
                    'fingerprint': 'SHA256:' + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip('='),
                }))
                metadata.chmod(0o600)
                print('Security key fixture ready', flush=True)
                while not stopped:
                    time.sleep(0.25)
            finally:
                process.terminate()
                process.wait(timeout=5)
                Path(args.metadata).unlink(missing_ok=True)


if __name__ == '__main__':
    main()
