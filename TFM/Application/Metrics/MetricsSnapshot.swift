import Foundation
import TermindDomain

/// A value-only view of the existing monitor. Reading never admits a host or starts collection.
@MainActor
protocol MetricsSnapshotReading: Sendable {
    func snapshot(for hostID: UUID) -> MetricsSnapshot?
}

nonisolated enum MetricsMonitorState: String, Sendable {
    case connecting, collecting, live, failed, paused, sleeping, stopped
    case awaitingAuthentication = "awaiting_authentication"
}

nonisolated struct MetricsSnapshot: Sendable {
    var capturedAt: Date
    var state: MetricsMonitorState
    var point: MetricsPoint?
    var history: [MetricsPoint] = []
    var gpuState: MetricsGPUState = .probing
    var gpu: NvidiaSnapshot?
    var gpuDate: Date?
    var processes: [MetricsProcess] = []
    var processesDate: Date?
    var processesFailed = false
    var filesystems: [MetricsFilesystem] = []
    var filesystemsDate: Date?
    var filesystemsFailed = false
}
