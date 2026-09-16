import Foundation

public nonisolated struct WorkspaceTemplate: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var layout: WorkspaceTemplateLayout

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && layout.paneCount >= 1
            && layout.isValid
    }

    public init(id: UUID = UUID(), name: String, layout: WorkspaceTemplateLayout) {
        self.id = id
        self.name = name
        self.layout = layout
    }
}

public nonisolated enum WorkspaceTemplatePane: Codable, Hashable, Sendable {
    case ssh(hostID: Host.ID)
    case sftp(hostID: Host.ID)
    case empty

    public var hostID: Host.ID? {
        switch self {
        case .ssh(let hostID), .sftp(let hostID): hostID
        case .empty: nil
        }
    }
}

public nonisolated enum WorkspaceTemplateSplitAxis: String, Codable, Hashable, Sendable {
    case horizontal
    case vertical
}

public nonisolated indirect enum WorkspaceTemplateLayout: Codable, Hashable, Sendable {
    case pane(WorkspaceTemplatePane)
    case split(
        axis: WorkspaceTemplateSplitAxis,
        fraction: Double,
        first: WorkspaceTemplateLayout,
        second: WorkspaceTemplateLayout
    )

    public var paneCount: Int {
        switch self {
        case .pane: 1
        case .split(_, _, let first, let second): first.paneCount + second.paneCount
        }
    }

    public var hostIDs: [Host.ID] {
        switch self {
        case .pane(let pane): pane.hostID.map { [$0] } ?? []
        case .split(_, _, let first, let second): first.hostIDs + second.hostIDs
        }
    }

    public var panes: [WorkspaceTemplatePane] {
        switch self {
        case .pane(let pane): [pane]
        case .split(_, _, let first, let second): first.panes + second.panes
        }
    }

    public var isValid: Bool {
        switch self {
        case .pane:
            true
        case .split(_, let fraction, let first, let second):
            fraction.isFinite && fraction > 0 && fraction < 1 && first.isValid && second.isValid
        }
    }
}
