#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Kaede Akino
# SPDX-License-Identifier: GPL-3.0-only

"""Small authenticated Telnet fixture for manual Termind testing."""

from __future__ import annotations

import argparse
import socket
import socketserver


IAC = 255
DONT = 254
DO = 253
WONT = 252
WILL = 251
SB = 250
SE = 240

BINARY = 0
ECHO = 1
SUPPRESS_GO_AHEAD = 3
TERMINAL_TYPE = 24
NAWS = 31


class TelnetReader:
    def __init__(self, connection: socket.socket) -> None:
        self.connection = connection
        self.state = "data"
        self.command = 0
        self.pending_cr = False

    def read_line(self, *, echo: bool) -> str | None:
        output = bytearray()
        while True:
            chunk = self.connection.recv(4096)
            if not chunk:
                return None
            for byte in chunk:
                value = self._consume(byte)
                if value is None:
                    continue
                if value in (10, 13):
                    if echo:
                        self.connection.sendall(b"\r\n")
                    return output.decode("utf-8", errors="replace").strip()
                if value in (8, 127):
                    if output:
                        output.pop()
                        if echo:
                            self.connection.sendall(b"\b \b")
                    continue
                output.append(value)
                if echo:
                    self.connection.sendall(bytes([value]))

    def _consume(self, byte: int) -> int | None:
        if self.state == "data":
            if byte == IAC:
                self.state = "iac"
                return None
            if self.pending_cr:
                self.pending_cr = False
                if byte in (0, 10):
                    return 10
            if byte == 13:
                self.pending_cr = True
                return None
            return byte

        if self.state == "iac":
            if byte == IAC:
                self.state = "data"
                return IAC
            if byte in (DO, DONT, WILL, WONT):
                self.command = byte
                self.state = "option"
                return None
            if byte == SB:
                self.state = "subnegotiation"
                return None
            self.state = "data"
            return None

        if self.state == "option":
            self.state = "data"
            return None

        if self.state == "subnegotiation":
            if byte == IAC:
                self.state = "subnegotiation_iac"
            return None

        if self.state == "subnegotiation_iac":
            self.state = "data" if byte == SE else "subnegotiation"
            return None

        self.state = "data"
        return None


class TelnetHandler(socketserver.BaseRequestHandler):
    server: "TelnetServer"

    def handle(self) -> None:
        try:
            self._handle()
        except (ConnectionError, TimeoutError):
            return

    def _handle(self) -> None:
        connection = self.request
        connection.settimeout(300)
        connection.sendall(
            bytes(
                [
                    IAC,
                    WILL,
                    ECHO,
                    IAC,
                    WILL,
                    SUPPRESS_GO_AHEAD,
                    IAC,
                    WILL,
                    BINARY,
                    IAC,
                    DO,
                    BINARY,
                    IAC,
                    DO,
                    TERMINAL_TYPE,
                    IAC,
                    DO,
                    NAWS,
                ]
            )
        )
        reader = TelnetReader(connection)

        for attempt in range(3):
            connection.sendall(b"\r\nTermind Telnet fixture\r\nlogin: ")
            username = reader.read_line(echo=True)
            if username is None:
                return
            connection.sendall(b"Password: ")
            password = reader.read_line(echo=False)
            if password is None:
                return
            connection.sendall(b"\r\n")
            if username == self.server.username and password == self.server.password:
                break
            remaining = 2 - attempt
            connection.sendall(f"Login incorrect ({remaining} attempts remaining)\r\n".encode())
        else:
            connection.sendall(b"Too many authentication failures.\r\n")
            return

        connection.sendall(
            b"Authentication accepted. Type 'help' for commands.\r\n"
        )
        while True:
            connection.sendall(f"{self.server.username}@termind:~$ ".encode())
            command = reader.read_line(echo=True)
            if command is None:
                return
            if command in ("exit", "quit", "logout"):
                connection.sendall(b"logout\r\n")
                return
            if command == "help":
                connection.sendall(b"help, whoami, charset, echo TEXT, exit\r\n")
            elif command == "whoami":
                connection.sendall(f"{self.server.username}\r\n".encode())
            elif command == "charset":
                connection.sendall(b"UTF-8\r\n")
            elif command.startswith("echo "):
                connection.sendall(command[5:].encode("utf-8") + b"\r\n")
            elif command:
                connection.sendall(f"command not found: {command}\r\n".encode())


class TelnetServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address: tuple[str, int], username: str, password: str) -> None:
        self.username = username
        self.password = password
        super().__init__(address, TelnetHandler)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=2323)
    parser.add_argument("--username", default="demo")
    parser.add_argument("--password", default="termind")
    args = parser.parse_args()

    with TelnetServer((args.host, args.port), args.username, args.password) as server:
        print(
            f"Telnet fixture listening on {args.host}:{args.port} "
            f"(username={args.username}, password={args.password})",
            flush=True,
        )
        server.serve_forever()


if __name__ == "__main__":
    main()
