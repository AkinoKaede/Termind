// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import Testing

@testable import Termind

@Suite
@MainActor
struct MCPClientSetupCommandTests {
    private let bridge = "/Applications/Termind.app/Contents/MacOS/termind-mcp"

    @Test
    func eachClientReceivesItsSupportedRegistrationArguments() throws {
        let setup = MCPClientSetupCommand(port: 7391, token: "test-token", bridgePath: bridge)
        let url = "http://localhost:7391/mcp"
        let cases: [(MCPClientSetupCommand.Client, [String])] = [
            (
                .codex,
                [
                    "mcp", "add", "termind", "--env", "TERMIND_MCP_URL=\(url)",
                    "--env", "TERMIND_MCP_TOKEN=test-token", "--", bridge,
                ]
            ),
            (
                .claudeCode,
                [
                    "mcp", "add", "--scope", "user", "--transport", "http", "--header",
                    "Authorization: Bearer test-token", "termind", url,
                ]
            ),
            (
                .copilot,
                [
                    "mcp", "add", "--transport", "http", "--header",
                    "Authorization: Bearer test-token", "termind", url,
                ]
            ),
            (
                .openClaw,
                [
                    "mcp", "add", "termind", "--url", url, "--transport", "streamable-http",
                    "--header", "Authorization=Bearer test-token",
                ]
            ),
            (
                .hermes,
                [
                    "mcp", "add", "termind", "--command", bridge, "--env",
                    "TERMIND_MCP_URL=\(url)", "TERMIND_MCP_TOKEN=test-token",
                ]
            ),
        ]
        for (client, expected) in cases {
            let command = try #require(setup.command(for: client))
            #expect(try shellArguments(command) == expected)
        }
    }

    @Test(arguments: MCPClientSetupCommand.Client.allCases)
    func commandsUseTheCurrentPortAndToken(client: MCPClientSetupCommand.Client) throws {
        let original = MCPClientSetupCommand(port: 7391, token: "old-token", bridgePath: bridge)
        let updated = MCPClientSetupCommand(port: 18443, token: "rotated-token", bridgePath: bridge)
        let oldCommand = try #require(original.command(for: client))
        let command = try #require(updated.command(for: client))
        let arguments = try shellArguments(command)
        #expect(command != oldCommand)
        #expect(arguments.contains { $0.contains("http://localhost:18443/mcp") })
        #expect(arguments.contains { $0.contains("rotated-token") })
        #expect(!command.contains("old-token"))
        #expect(!command.contains(":7391/"))
    }

    @Test(arguments: MCPClientSetupCommand.Client.allCases)
    func missingTokenDisablesEveryClient(client: MCPClientSetupCommand.Client) {
        let setup = MCPClientSetupCommand(port: 7391, token: "", bridgePath: bridge)
        #expect(setup.command(for: client) == nil)
    }

    @Test(arguments: [nil, ""] as [String?])
    func missingBridgeDisablesOnlyBridgeClients(path: String?) {
        let setup = MCPClientSetupCommand(port: 7391, token: "test-token", bridgePath: path)
        #expect(setup.command(for: .codex) == nil)
        #expect(setup.command(for: .hermes) == nil)
        for client in [MCPClientSetupCommand.Client.claudeCode, .copilot, .openClaw] {
            #expect(setup.command(for: client) != nil)
        }
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func shellMetacharactersRemainLiteral(shell: String) throws {
        let path = "/Applications/Kaede's 工具 $HOME `printf injected` $(printf injected); & Termind.app/termind-mcp"
        let token = "test'\" $HOME `printf injected` $(printf injected); & \\ token\nnext-line"
        let setup = MCPClientSetupCommand(port: 7391, token: token, bridgePath: path)
        for client in MCPClientSetupCommand.Client.allCases {
            let command = try #require(setup.command(for: client))
            let arguments = try shellArguments(command, shell: shell)
            if client.requiresBridge {
                #expect(arguments.contains(path))
                #expect(arguments.contains("TERMIND_MCP_TOKEN=\(token)"))
            } else {
                let separator = client == .openClaw ? "=" : ": "
                #expect(arguments.contains("Authorization\(separator)Bearer \(token)"))
            }
        }
    }

    /// Parse with real shells, substituting inert CLI functions so no client config is touched.
    private func shellArguments(_ command: String, shell: String = "/bin/sh") throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        let stubs = ["codex", "claude", "copilot", "openclaw", "hermes"].map {
            "\($0)() { printf '%s\\0' \"$@\"; };"
        }.joined(separator: "\n")
        process.arguments = ["-f", "-c", stubs + "\n" + command]
        process.environment = [:]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false)
            .dropLast().map(String.init)
    }
}
