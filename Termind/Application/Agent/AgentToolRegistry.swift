import Foundation

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

    subscript(name: String) -> AnyAgentTool? { byName[name] }

    func filtering(
        _ isIncluded: (AgentToolDescriptor) -> Bool
    ) -> AgentToolRegistry {
        AgentToolRegistry(byName.values.filter { isIncluded($0.descriptor) })
    }

    /// Sorted, because the tool list is part of the request's cacheable prefix
    /// and a dictionary's iteration order is not stable across launches.
    var descriptors: [AgentToolDescriptor] {
        byName.values.map(\.descriptor).sorted { $0.qualifiedName < $1.qualifiedName }
    }

    /// Primarily useful to focused tests and secondary export surfaces that
    /// need to execute the same catalog-resolved definitions.
    var registeredTools: [AnyAgentTool] {
        byName.values.sorted { $0.descriptor.qualifiedName < $1.descriptor.qualifiedName }
    }
}
