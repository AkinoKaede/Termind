import Foundation

/// A run-scoped view of this device's open terminals. App adapters own the live
/// models; neither this capability nor its closures are stored on a conversation.
nonisolated public struct AgentPaneAccess: Sendable {
    nonisolated public struct Pane: Sendable, Equatable {
        public var id: UUID
        public var title: String
        public var hostID: UUID?
        public var workspace: String
        public var window: String
        public var isActive: Bool
        public var isCurrent: Bool

        public init(
            id: UUID, title: String, hostID: UUID?, workspace: String, window: String,
            isActive: Bool, isCurrent: Bool
        ) {
            self.id = id
            self.title = title
            self.hostID = hostID
            self.workspace = workspace
            self.window = window
            self.isActive = isActive
            self.isCurrent = isCurrent
        }
    }

    nonisolated public enum Read: Sendable, Equatable {
        case closed
        case notConnected
        case noSurface
        case text(Pane, String)
    }

    private let listBody: @MainActor @Sendable () -> [Pane]
    private let readBody: @MainActor @Sendable (UUID) -> Read

    public init(
        list: @escaping @MainActor @Sendable () -> [Pane],
        read: @escaping @MainActor @Sendable (UUID) -> Read
    ) {
        listBody = list
        readBody = read
    }

    @MainActor public func list() -> [Pane] { listBody() }
    @MainActor public func read(_ id: UUID) -> Read { readBody(id) }
}
