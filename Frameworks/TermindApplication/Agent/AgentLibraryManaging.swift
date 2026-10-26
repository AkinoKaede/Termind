// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

@MainActor
public protocol AgentSnippetManaging: AnyObject {
    var snippets: [Snippet] { get }
    var snippetPackages: [SnippetPackage] { get }
    func containsHost(_ id: UUID) -> Bool
    func requireExecutionHost(_ id: UUID) throws
    func save(_ snippet: Snippet) throws
    func save(_ package: SnippetPackage) throws
    func removeSnippet(_ id: UUID) throws
    func removePackage(_ id: UUID, keepSnippets: Bool) throws
}

extension SnippetLibraryModel: AgentSnippetManaging {
    public func containsHost(_ id: UUID) -> Bool { hosts.contains { $0.id == id } }
}

@MainActor
public protocol AgentForwardingManaging: AnyObject {
    var rules: [PortForwardingRule] { get }
    func save(_ rule: PortForwardingRule) throws -> PortForwardingRule
    func delete(_ id: UUID) throws
    func requireStart(_ id: UUID) throws
}

extension ForwardingLibraryModel: AgentForwardingManaging {}

public nonisolated struct AgentForwardingStatus: Sendable {
    public var state: String
    public var requiresUserAction: Bool

    public init(state: String, requiresUserAction: Bool = false) {
        self.state = state
        self.requiresUserAction = requiresUserAction
    }
}

@MainActor
public protocol AgentForwardingControlling: AnyObject {
    func start(_ id: UUID)
    func stop(_ id: UUID)
    func managementStatus(_ id: UUID) -> AgentForwardingStatus
}

public nonisolated struct AgentMetricsInfo: Sendable {
    public var selection: MetricsSelection
    public var state: String
    public var availableDisks: [String]
    public var availableInterfaces: [String]

    public init(
        selection: MetricsSelection, state: String, availableDisks: [String] = [], availableInterfaces: [String] = []
    ) {
        self.selection = selection
        self.state = state
        self.availableDisks = availableDisks
        self.availableInterfaces = availableInterfaces
    }
}

@MainActor
public protocol AgentMetricsManaging: AnyObject {
    var managedMetrics: [AgentMetricsInfo] { get }
    func saveSelection(_ selection: MetricsSelection) throws
    func removeSelection(_ id: UUID) throws
    func requestRefresh(_ id: UUID) -> Bool
}

extension ServerMetricsModel: AgentMetricsManaging {
    public var managedMetrics: [AgentMetricsInfo] {
        selections.map { selection in
            let server = servers.first { $0.id == selection.id }
            return AgentMetricsInfo(
                selection: selection,
                state: snapshot(for: selection.id)?.state.rawValue ?? "unavailable",
                availableDisks: server?.disks ?? [], availableInterfaces: server?.interfaces ?? [])
        }
    }

}
