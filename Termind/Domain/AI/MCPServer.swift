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
    /// Stable model-facing namespace. An empty value is used only while a new
    /// server draft is still deriving its ID from `name`.
    var namespaceID: String
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

    init(
        id: UUID = UUID(), name: String, namespaceID: String? = nil,
        transport: Transport = .streamableHTTP, url: String = "",
        isEnabled: Bool = true, credentialRef: String = "",
        headers: [MCPHeader] = [], tools: [MCPTool] = [],
        negotiatedVersion: String = "", lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.namespaceID = namespaceID ?? MCPToolNaming.namespaceID(from: name)
        self.transport = transport
        self.url = url
        self.isEnabled = isEnabled
        self.credentialRef = credentialRef
        self.headers = headers
        self.tools = tools
        self.negotiatedVersion = negotiatedVersion
        self.lastConnectedAt = lastConnectedAt
    }

    /// The locked namespace, or the live derived value for an unlocked draft.
    var effectiveNamespaceID: String {
        namespaceID.isEmpty ? MCPToolNaming.namespaceID(from: name) : namespaceID
    }

    var enabledTools: [MCPTool] {
        tools.filter { $0.accessPolicy != .disabled }
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

/// Shared naming rules for MCP namespaces and their model-visible functions.
nonisolated enum MCPToolNaming {
    static func namespaceID(from name: String) -> String {
        normalize(name, emptyFallback: "")
    }

    static func functionName(from remoteName: String) -> String {
        normalize(remoteName, emptyFallback: "tool")
    }

    /// Returns stable, unique leaf names keyed by the server-reported tool ID.
    static func functionNames(for tools: [MCPTool]) -> [String: String] {
        var taken = Set<String>()
        var result: [String: String] = [:]
        for tool in tools.sorted(by: { $0.id < $1.id }) {
            let base = functionName(from: tool.id)
            var candidate = base
            var suffix = 2
            while taken.contains(candidate) {
                candidate = "\(base)_\(suffix)"
                suffix += 1
            }
            taken.insert(candidate)
            result[tool.id] = candidate
        }
        return result
    }

    static func qualifiedName(namespace: String, function: String) -> String {
        "\(namespace).\(function)"
    }

    private static func normalize(_ value: String, emptyFallback: String) -> String {
        var result = ""
        var pendingSeparator = false
        for scalar in value.unicodeScalars {
            let code = scalar.value
            let isUppercase = (65...90).contains(code)
            let isLowercase = (97...122).contains(code)
            let isDigit = (48...57).contains(code)
            if isUppercase || isLowercase || isDigit || code == 95 || code == 45 {
                if pendingSeparator, !result.isEmpty,
                    result.last != "_", result.last != "-"
                {
                    result.append("_")
                }
                pendingSeparator = false
                if isUppercase {
                    result.unicodeScalars.append(UnicodeScalar(code + 32)!)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            } else {
                pendingSeparator = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "_-")).isEmpty
            ? emptyFallback
            : result.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
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
/// `accessPolicy` defaults to `alwaysAsk`, and that default is the point rather
/// than caution. An MCP tool is a command fetched over the network from a server
/// the model can talk to, so a newly discovered tool must not silently inherit a
/// more permissive conversation setting.
nonisolated struct MCPTool: Identifiable, Hashable, Sendable {
    nonisolated enum AccessPolicy: String, CaseIterable, Identifiable, Hashable, Sendable {
        case disabled
        case alwaysAsk
        case followPermissions

        nonisolated var id: String { rawValue }
    }

    /// The tool name as the server reports it. Its identity, since MCP names
    /// are unique per server.
    var id: String
    var title: String = ""
    var summary: String = ""
    var inputSchema: AgentJSONValue = .object([
        "type": .string("object"), "properties": .object([:])
    ])
    var annotations: MCPToolAnnotations = MCPToolAnnotations()
    var accessPolicy: AccessPolicy = .alwaysAsk

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return id.lowercased().contains(q) || summary.lowercased().contains(q)
    }
}

/// Hints supplied by the remote MCP server. They inform risk signals but can
/// never prove a call safe or bypass Termind's local approval policy.
nonisolated struct MCPToolAnnotations: Hashable, Sendable, Codable {
    var title: String?
    var readOnlyHint: Bool?
    var destructiveHint: Bool?
    var idempotentHint: Bool?
    var openWorldHint: Bool?
}
