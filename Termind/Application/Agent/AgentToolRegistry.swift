import Foundation

/// One source of tools.
///
/// The seam for adding capability: built-ins and MCP are two implementations of
/// the same thing, and a third — a plugin, a per-host tool set, a workspace
/// script — is a new conformer rather than another line inside `AppModel` and
/// another `+` in the runtime's initializer.
///
/// Synchronous on purpose. Nothing here discovers anything — MCP schemas are
/// already stored on `MCPServer` by the time a run starts — and an `async`
/// requirement no conformer needs would drag every call site into an async
/// context for a future that may never arrive. A provider that genuinely has to
/// go and look belongs inside the run, where cancellation and the run's own
/// failure handling already exist.
nonisolated protocol AgentToolProviding: Sendable {
    func tools() -> [AnyAgentTool]
}

/// The resolved tool set for one run, with the name collisions already settled.
nonisolated struct AgentToolRegistry: Sendable {
    private let byName: [String: AnyAgentTool]

    /// First registration wins.
    ///
    /// `Dictionary(uniqueKeysWithValues:)` traps on a duplicate, and one MCP
    /// server whose two tool names sanitize to the same string is enough to
    /// take the app down — from data a remote server controls. Built-ins are
    /// listed first by every caller, so a remote name can never shadow one.
    init(_ tools: [AnyAgentTool]) {
        byName = Dictionary(
            tools.map { ($0.descriptor.qualifiedName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Resolves providers in order, which is also the precedence order.
    init(_ providers: [any AgentToolProviding]) {
        self.init(providers.flatMap { $0.tools() })
    }

    subscript(name: String) -> AnyAgentTool? { byName[name] }

    var isEmpty: Bool { byName.isEmpty }

    /// Sorted, because the tool list is part of the request's cacheable prefix
    /// and a dictionary's iteration order is not stable across launches.
    var descriptors: [AgentToolDescriptor] {
        byName.values.map(\.descriptor).sorted { $0.qualifiedName < $1.qualifiedName }
    }
}

/// Wraps an already-resolved array so a fixed tool set is a provider like any
/// other. Tests and the built-in set both use it.
nonisolated struct AgentStaticToolProvider: AgentToolProviding {
    var provided: [AnyAgentTool]

    init(_ provided: [AnyAgentTool]) {
        self.provided = provided
    }

    func tools() -> [AnyAgentTool] { provided }
}
