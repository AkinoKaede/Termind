// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Presentation-only commands for registering the local server with external clients.
struct MCPClientSetupCommand {
    enum Client: String, CaseIterable, Identifiable {
        case codex = "Codex"
        case claudeCode = "Claude Code"
        case copilot = "GitHub Copilot CLI"
        case openClaw = "OpenClaw"
        case hermes = "Hermes Agent"

        var id: Self { self }

        var requiresBridge: Bool { self == .codex || self == .hermes }
    }

    let port: Int
    let token: String
    let bridgePath: String?

    func command(for client: Client) -> String? {
        guard !token.isEmpty else { return nil }
        if client.requiresBridge, bridgePath?.isEmpty != false { return nil }

        let url = "http://localhost:\(port)/mcp"
        let quotedURL = Self.quote(url)
        let header = Self.quote("Authorization: Bearer \(token)")
        let urlEnvironment = Self.quote("TERMIND_MCP_URL=\(url)")
        let tokenEnvironment = Self.quote("TERMIND_MCP_TOKEN=\(token)")

        switch client {
        case .codex:
            guard let bridgePath else { return nil }
            return
                "codex mcp add termind --env \(urlEnvironment) --env \(tokenEnvironment) -- \(Self.quote(bridgePath))"
        case .claudeCode:
            return "claude mcp add --scope user --transport http --header \(header) termind \(quotedURL)"
        case .copilot:
            return "copilot mcp add --transport http --header \(header) termind \(quotedURL)"
        case .openClaw:
            let header = Self.quote("Authorization=Bearer \(token)")
            return "openclaw mcp add termind --url \(quotedURL) --transport streamable-http --header \(header)"
        case .hermes:
            guard let bridgePath else { return nil }
            return
                "hermes mcp add termind --command \(Self.quote(bridgePath)) --env \(urlEnvironment) \(tokenEnvironment)"
        }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
