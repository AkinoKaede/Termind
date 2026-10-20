#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Kaede Akino
# SPDX-License-Identifier: GPL-3.0-only

"""Local SSH fixture that withholds exec close acknowledgements.

Run with --metadata /tmp/pty-lifecycle.json and pass the path to tests as
TEST_RUNNER_TERMIND_PTY_LIFECYCLE_FIXTURE. Uses the authentication fixture's
in-memory SFTP server; never runs the requested commands. Requires paramiko.
Each exec command supplies a UUID so tests can observe native close independently
of Swift task completion. Only closing the transport releases the stalled exec.
"""
import importlib.util
from pathlib import Path
import sys
import threading

spec = importlib.util.spec_from_file_location(
    "authentication_fixture", Path(__file__).with_name("ssh-authentication-fixture.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)

metadata = Path(sys.argv[sys.argv.index("--metadata") + 1])
events = Path(str(metadata) + ".events")
events.write_text("")
lock = threading.Lock()


def record(event):
    with lock, events.open("a") as output:
        output.write(event + "\n")


original_exec = fixture.Authentication.check_channel_exec_request
original_close = fixture.paramiko.Transport._channel_handler_table[fixture.paramiko.common.MSG_CHANNEL_CLOSE]


def execute(self, channel, command):
    text = command.decode()
    marker = "fixture-stalled-close "
    if marker not in text:
        return original_exec(self, channel, command)
    token = text.split(marker, 1)[1][:36]
    channel.lifecycle_token = token
    self.transport.lifecycle_token = token
    record("exec " + token)
    return True


def close(channel, message):
    token = getattr(channel, "lifecycle_token", None)
    if token:
        record("close " + token)
        # Leave the channel open, modelling a peer that never acknowledges CLOSE.
        return
    return original_close(channel, message)


original_transport_close = fixture.paramiko.Transport.close


def close_transport(self):
    original_transport_close(self)
    token = getattr(self, "lifecycle_token", None)
    if token:
        record("transport-closed " + token)


fixture.Authentication.check_channel_exec_request = execute
fixture.paramiko.Transport._channel_handler_table[fixture.paramiko.common.MSG_CHANNEL_CLOSE] = close
fixture.paramiko.Transport.close = close_transport
try:
    fixture.main()
finally:
    events.unlink(missing_ok=True)
