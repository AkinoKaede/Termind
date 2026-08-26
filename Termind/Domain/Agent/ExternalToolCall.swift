import Foundation

nonisolated struct ExternalToolCall: Identifiable, Hashable, Sendable {
    nonisolated enum Risk: String, Hashable, Sendable, Codable {
        case readOnly, modifiesState, destructive

        var label: String {
            switch self {
            case .readOnly: String(localized: "Read-only")
            case .modifiesState: String(localized: "Modifies state")
            case .destructive: String(localized: "Destructive")
            }
        }
    }

    nonisolated enum Status: String, Hashable, Sendable, Codable {
        case running, ok, error, denied
    }

    var id: UUID = UUID()
    var runID: UUID
    var clientName: String
    var toolName: String
    var hostID: Host.ID?
    var hostDisplayName: String?
    var summary: String
    var risk: Risk
    var status: Status = .running
    var exitCode: Int?
    var bytesRead: Int?
    var bytesWritten: Int?
    var startedAt: Date
    var finishedAt: Date?

    var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }
}
