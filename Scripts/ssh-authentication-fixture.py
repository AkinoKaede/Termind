#!/usr/bin/env python3
"""Loopback-only SSH authentication fixture; never executes client commands.

Run with a temporary virtual environment containing paramiko==4.0.0:
  python Scripts/ssh-authentication-fixture.py --metadata /tmp/ssh-fixture.json
Pass that path to tests as TEST_RUNNER_TERMIND_SSH_FIXTURE. Keys are generated
in memory; the metadata file is removed when this process exits.
"""
import argparse
import base64
import hashlib
import io
import json
import os
import select
import signal
import socket
import threading
import time

import paramiko


class MemoryFile(paramiko.SFTPHandle):
    def __init__(self, data):
        super().__init__()
        self.data = data

    def read(self, offset, length):
        return bytes(self.data[offset:offset + length])

    def write(self, offset, data):
        self.data[offset:offset + len(data)] = data
        return paramiko.SFTP_OK

    def stat(self):
        return Files.attributes(self.data)


class Files(paramiko.SFTPServerInterface):
    # Per-connection test data; never touches the local file system.
    def __init__(self, server, *args, **kwargs):
        super().__init__(server, *args, **kwargs)
        self.files = {"/fixture.txt": bytearray(b"fixture\n")}

    @staticmethod
    def attributes(data):
        item = paramiko.SFTPAttributes()
        item.st_mode = 0o100644
        item.st_size = len(data)
        return item

    def canonicalize(self, path):
        return "/" if path == "." else path

    def list_folder(self, path):
        result = []
        for name, data in self.files.items():
            item = self.attributes(data)
            item.filename = name.rsplit("/", 1)[-1]
            result.append(item)
        return result

    def stat(self, path):
        if path not in self.files:
            return paramiko.SFTP_NO_SUCH_FILE
        return self.attributes(self.files[path])

    lstat = stat

    def open(self, path, flags, attr):
        if path not in self.files:
            if not flags & os.O_CREAT:
                return paramiko.SFTP_NO_SUCH_FILE
            self.files[path] = bytearray()
        elif flags & os.O_EXCL:
            return paramiko.SFTP_FAILURE
        if flags & os.O_TRUNC:
            self.files[path].clear()
        return MemoryFile(self.files[path])

    def remove(self, path):
        if path not in self.files:
            return paramiko.SFTP_NO_SUCH_FILE
        del self.files[path]
        return paramiko.SFTP_OK

    def rename(self, source, destination):
        if source not in self.files:
            return paramiko.SFTP_NO_SUCH_FILE
        if destination in self.files:
            return paramiko.SFTP_FAILURE
        self.files[destination] = self.files.pop(source)
        return paramiko.SFTP_OK

    def posix_rename(self, source, destination):
        if source not in self.files:
            return paramiko.SFTP_NO_SUCH_FILE
        self.files[destination] = self.files.pop(source)
        return paramiko.SFTP_OK


class Authentication(paramiko.ServerInterface):
    def __init__(self, client_key):
        self.listeners = {}
        self.client_key = client_key
        self.user = ""
        self.factor = False
        self.round = 0
        self.destinations = {}
        self.shells = set()

    def get_allowed_auths(self, username):
        if self.factor:
            return "password" if username == "kbd-password" else "keyboard-interactive"
        return {
            "password": "password", "password-mfa": "password",
            "publickey": "publickey", "encrypted-key": "publickey",
            "publickey-mfa": "publickey", "reject": "password",
            "key-password": "publickey,password",
        }.get(username, "keyboard-interactive")

    def check_auth_none(self, username):
        self.user = username
        return paramiko.AUTH_SUCCESSFUL if username in ("none", "none-slow-forward") else paramiko.AUTH_FAILED

    def check_auth_password(self, username, password):
        if password != "fixture-password":
            return paramiko.AUTH_FAILED
        if username == "password-mfa":
            self.factor = True
            return paramiko.AUTH_PARTIALLY_SUCCESSFUL
        accepted = username in ("password", "key-password") or (username == "kbd-password" and self.factor)
        return paramiko.AUTH_SUCCESSFUL if accepted else paramiko.AUTH_FAILED

    def check_auth_publickey(self, username, key):
        if username in ("publickey", "encrypted-key") and key == self.client_key:
            return paramiko.AUTH_SUCCESSFUL
        if username == "publickey-mfa" and key == self.client_key:
            self.factor = True
            return paramiko.AUTH_PARTIALLY_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def check_auth_interactive(self, username, submethods):
        self.round = 1
        if username in ("password-mfa", "publickey-mfa") and not self.factor:
            return paramiko.AUTH_FAILED
        if username == "push":
            return paramiko.InteractiveQuery("PAM", "Approve this login on your device.")
        if username == "multi":
            return paramiko.InteractiveQuery("PAM 登录", "Two questions", ("用户名", True), ("OTP", False))
        return paramiko.InteractiveQuery("OTP", "Enter the current code.", ("OTP", False))

    def check_auth_interactive_response(self, responses):
        if self.user == "kbd-password" and responses == ["123456"]:
            self.factor = True
            return paramiko.AUTH_PARTIALLY_SUCCESSFUL
        if self.user == "multi":
            if self.round == 1 and responses == ["部署 user", "123456"]:
                self.round += 1
                return paramiko.InteractiveQuery("PAM", "Empty answers are valid.", ("Optional", False))
            return paramiko.AUTH_SUCCESSFUL if self.round == 2 and responses == [""] else paramiko.AUTH_FAILED
        if self.user == "push":
            return paramiko.AUTH_SUCCESSFUL if responses == [] else paramiko.AUTH_FAILED
        return paramiko.AUTH_SUCCESSFUL if responses == ["123456"] else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_exec_request(self, channel, command):
        def reply():
            channel.sendall(b"fixture\n")
            channel.send_exit_status(0)
            channel.shutdown_write()
        threading.Thread(target=reply, daemon=True).start()
        return True

    def check_channel_pty_request(self, *args):
        return True

    def check_channel_shell_request(self, channel):
        self.shells.add(channel.get_id())
        return True

    def check_channel_direct_tcpip_request(self, chanid, origin, destination):
        # Allow routing only back to this fixture, never to other services.
        if destination not in self.allowed_destinations:
            return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        self.destinations[chanid] = destination
        return paramiko.OPEN_SUCCEEDED

    def check_port_forward_request(self, address, port):
        if self.user == "none-slow-forward":
            time.sleep(0.1)
        if address not in ("127.0.0.1", "::1"):
            return False
        listener = socket.socket(socket.AF_INET6 if ":" in address else socket.AF_INET)
        try:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind((address, port))
            listener.listen(128)
            listener.settimeout(0.2)
        except OSError as error:
            print(f"Fixture bind {address}:{port} failed: {error}", flush=True)
            listener.close()
            return False
        bound = listener.getsockname()[1]
        self.listeners[(address, bound)] = listener

        def accept():
            while self.transport.is_active():
                try:
                    peer, origin = listener.accept()
                    channel = self.transport.open_forwarded_tcpip_channel(origin[:2], (address, bound))
                    threading.Thread(target=relay_peer, args=(channel, peer), daemon=True).start()
                except socket.timeout:
                    continue
                except (OSError, EOFError, paramiko.SSHException):
                    break

        threading.Thread(target=accept, daemon=True).start()
        return bound

    def cancel_port_forward_request(self, address, port):
        listener = self.listeners.pop((address, port), None)
        if listener:
            listener.close()


def relay_peer(channel, peer):
    with peer:
        try:
            readers = [channel, peer]
            while readers:
                ready, _, _ = select.select(readers, [], [], 1)
                for source in ready:
                    destination = peer if source is channel else channel
                    data = source.recv(32768)
                    if data:
                        destination.sendall(data)
                    else:
                        readers.remove(source)
                        if destination is channel:
                            channel.shutdown_write()
                        else:
                            peer.shutdown(socket.SHUT_WR)
        except (OSError, EOFError, paramiko.SSHException):
            pass
        finally:
            try:
                channel.close()
            except (OSError, EOFError, paramiko.SSHException):
                pass


def echo_server(listener):
    def echo(peer):
        with peer:
            try:
                while data := peer.recv(65536):
                    peer.sendall(data)
            except OSError:
                pass
    while True:
        try:
            peer, _ = listener.accept()
            threading.Thread(target=echo, args=(peer,), daemon=True).start()
        except OSError:
            return


def relay(channel, destination):
    try:
        relay_peer(channel, socket.create_connection(destination))
    except OSError:
        channel.close()


def serve(sock, host_key, client_key, port, echo_port):
    transport = paramiko.Transport(sock)
    transport.banner_timeout = 120
    transport.auth_timeout = 120
    transport.add_server_key(host_key)
    transport.set_subsystem_handler("sftp", paramiko.SFTPServer, Files)
    server = Authentication(client_key)
    server.port = port
    server.transport = transport
    server.allowed_destinations = {("127.0.0.1", port), ("127.0.0.1", echo_port), ("::1", echo_port)}
    channels = []
    try:
        transport.start_server(server=server)
        while transport.is_active():
            channel = transport.accept(0.2)
            if channel:
                channels.append(channel)
                destination = server.destinations.get(channel.get_id())
                if destination:
                    threading.Thread(target=relay, args=(channel, destination), daemon=True).start()
    except (EOFError, OSError, paramiko.SSHException):
        pass
    finally:
        for listener in server.listeners.values():
            listener.close()
        transport.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata", required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    host_key = paramiko.RSAKey.generate(2048)
    client_key = paramiko.RSAKey.generate(2048)
    private = io.StringIO()
    client_key.write_private_key(private)
    encrypted_private = io.StringIO()
    client_key.write_private_key(encrypted_private, password="fixture-passphrase")
    with socket.socket() as listener, socket.socket() as echo_listener:
        echo_listener.bind(("127.0.0.1", 0))
        echo_listener.listen(128)
        echo_port = echo_listener.getsockname()[1]
        threading.Thread(target=echo_server, args=(echo_listener,), daemon=True).start()
        listener.bind(("127.0.0.1", 0))
        listener.listen(128)
        port = listener.getsockname()[1]
        fingerprint = base64.b64encode(hashlib.sha256(host_key.asbytes()).digest()).decode().rstrip("=")
        metadata = {
            "port": port,
            "echoPort": echo_port,
            "privateKey": private.getvalue(),
            "encryptedPrivateKey": encrypted_private.getvalue(),
            "hostFingerprint": "SHA256:" + fingerprint,
        }
        # Ephemeral test material only, never a user credential.
        fd = os.open(args.metadata, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as output:
            json.dump(metadata, output)
        print(f"SSH fixture listening on 127.0.0.1:{port}", flush=True)
        try:
            while True:
                sock, _ = listener.accept()
                threading.Thread(target=serve, args=(sock, host_key, client_key, port, echo_port), daemon=True).start()
        except KeyboardInterrupt:
            pass
        finally:
            os.unlink(args.metadata)


if __name__ == "__main__":
    main()
