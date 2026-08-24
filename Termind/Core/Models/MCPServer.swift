import Foundation

/// An MCP server Termind can ask for tools.
///
/// HTTP only — there is no stdio transport here, and that is a property of the
/// app rather than an omission. Termind runs under the App Sandbox, so launching
/// an arbitrary local process is not something it can do. Every server reached
/// from here is one that already exists at a URL.
///
/// Nothing secret is stored. `credentialRef` files the bearer token the way
/// `Identity.credentialRef` files a password; `headers` is for the things that
/// are not secrets, and the editor says so rather than leaving it to be assumed.
nonisolated struct MCPServer: Identifiable, Hashable, Sendable {
    /// The two HTTP transports MCP has defined.
    ///
    /// `streamableHTTP` is the current one; `sse` is the 2024-11-05 transport it
    /// replaced, kept because a great many deployed servers still only speak it
    /// and the specification gives it a twelve-month deprecation window.
    nonisolated enum Transport: String, Codable, Sendable, CaseIterable, Identifiable {
        case streamableHTTP
        case sse

        nonisolated var id: String { rawValue }

        var displayName: String {
            switch self {
            case .streamableHTTP: String(localized: "Streamable HTTP")
            case .sse: String(localized: "SSE (legacy)")
            }
        }

        var detail: String {
            switch self {
            case .streamableHTTP:
                String(localized: "The current transport, using one endpoint for POST and GET.")
            case .sse:
                String(localized: "Legacy transport using a GET stream and a separate POST endpoint.")
            }
        }
    }

    var id: UUID = UUID()
    var name: String
    var transport: Transport = .streamableHTTP
    /// The MCP endpoint. One URL for Streamable HTTP; for SSE this is the URL
    /// the stream is opened on, and the POST endpoint arrives on that stream.
    var url: String = ""
    var isEnabled: Bool = true
    /// A bearer token, by reference. Most authenticated servers want exactly
    /// this one header, so it gets a field of its own rather than being one row
    /// among the custom headers where it would be stored in the clear.
    var credentialRef: String = ""
    /// Non-secret extras — a tenant id, an API version.
    var headers: [MCPHeader] = []
    /// What the last successful connection reported. Emptied by a failure, so
    /// a stale list cannot be mistaken for a live one.
    var tools: [MCPTool] = []
    /// The protocol version the server agreed to, once it has said.
    var negotiatedVersion: String = ""
    var lastConnectedAt: Date?

    var enabledTools: [MCPTool] {
        tools.filter(\.isEnabled)
    }

    var isReachable: Bool {
        !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return name.lowercased().contains(q) || url.lowercased().contains(q)
    }
}

/// One custom HTTP header sent with every request to a server.
///
/// Deliberately not where a token goes. Values here are held in the clear
/// alongside the rest of the configuration, which is fine for
/// `X-Tenant: acme` and wrong for `Authorization: Bearer …` — that is what
/// `MCPServer.credentialRef` is for.
nonisolated struct MCPHeader: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    var value: String = ""

    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// One tool a server offers.
///
/// `requiresApproval` defaults to `true`, and that default is the point rather
/// than caution. Termind's rule is that nothing runs on the user's say-so alone —
/// an AI-proposed command is always a click away from the PTY, never closer. An
/// MCP tool is a command by another name, and it arrives from a list fetched
/// over the network from a server the model can talk to. If the default went
/// the other way, the one rule the whole feature rests on would have a hole in
/// it that nobody opened deliberately.
nonisolated struct MCPTool: Identifiable, Hashable, Sendable {
    /// The tool name as the server reports it. Its identity, since MCP names
    /// are unique per server.
    var id: String
    var summary: String = ""
    var isEnabled: Bool = true
    var requiresApproval: Bool = true

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return id.lowercased().contains(q) || summary.lowercased().contains(q)
    }
}
