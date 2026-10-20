#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Kaede Akino
# SPDX-License-Identifier: GPL-3.0-only

"""Exercise a built termind-mcp executable against a deterministic loopback server."""

import http.server
import json
import subprocess
import sys
import threading


def check(executable, modern):
    observed = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            message = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            observed.append((message["method"], dict(self.headers)))
            reply = {"jsonrpc": "2.0", "id": message.get("id", 1)}
            if message["method"] == "initialize":
                reply["result"] = {"protocolVersion": "2024-11-05"}
                status = 200
            else:
                reply["error"] = {
                    "code": -32022 if modern else -32602,
                    "message": "Test protocol error",
                    "data": {"supported": ["2026-07-28"]},
                }
                status = 400
            data = json.dumps(reply).encode()
            self.send_response(status)
            if message["method"] == "initialize":
                self.send_header("Mcp-Session-Id", "test-session")
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_DELETE(self):
            observed.append(("DELETE", dict(self.headers)))
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    call = {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "中文", "arguments": {}}}
    messages = []
    if modern:
        call["params"]["_meta"] = {
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": {},
        }
    else:
        messages.append({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}})
    messages.append(call)
    try:
        result = subprocess.run(
            [executable, "--url", f"http://127.0.0.1:{server.server_port}/mcp", "--token", "test-only"],
            input="".join(json.dumps(message) + "\n" for message in messages),
            capture_output=True, text=True, timeout=10, check=True,
        )
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        assert replies[-1]["error"]["code"] == (-32022 if modern else -32602), replies
        call_headers = {key.lower(): value for method, headers in observed if method == "tools/call" for key, value in headers.items()}
        if modern:
            assert call_headers["mcp-method"] == "tools/call"
            assert call_headers["mcp-name"] == "=?base64?5Lit5paH?="
            assert call_headers["mcp-protocol-version"] == "2026-07-28"
            assert "mcp-session-id" not in call_headers
            assert len(observed) == 1, observed
        else:
            assert call_headers["mcp-session-id"] == "test-session"
            assert call_headers["mcp-protocol-version"] == "2024-11-05"
            assert observed[-1][0] == "DELETE"
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python3 Scripts/check-mcp-bridge.py /path/to/termind-mcp")
    check(sys.argv[1], modern=True)
    check(sys.argv[1], modern=False)
    print("MCP bridge modern and legacy headers, lifecycle, and JSON-RPC error passthrough passed.")
