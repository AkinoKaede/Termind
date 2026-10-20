// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

/// A value-only view of the existing monitor. Reading never admits a host or starts collection.
@MainActor
public protocol MetricsSnapshotReading: Sendable {
    func snapshot(for hostID: UUID) -> MetricsSnapshot?
}

public nonisolated enum MetricsMonitorState: String, Sendable {
    case connecting, collecting, live, failed, paused, sleeping, stopped, locked
    case awaitingAuthentication = "awaiting_authentication"
}

public nonisolated struct MetricsSnapshot: Sendable {
    public var capturedAt: Date
    public var state: MetricsMonitorState
    public var point: MetricsPoint?
    public var history: [MetricsPoint] = []
    public var gpuState: MetricsGPUState = .probing
    public var gpu: NvidiaSnapshot?
    public var gpuDate: Date?
    public var processes: [MetricsProcess] = []
    public var processesDate: Date?
    public var processesFailed = false
    public var filesystems: [MetricsFilesystem] = []
    public var filesystemsDate: Date?
    public var filesystemsFailed = false
    public init(
        capturedAt: Date, state: MetricsMonitorState, point: MetricsPoint? = nil, history: [MetricsPoint] = [],
        gpuState: MetricsGPUState = .probing, gpu: NvidiaSnapshot? = nil, gpuDate: Date? = nil,
        processes: [MetricsProcess] = [], processesDate: Date? = nil, processesFailed: Bool = false,
        filesystems: [MetricsFilesystem] = [], filesystemsDate: Date? = nil, filesystemsFailed: Bool = false
    ) {
        self.capturedAt = capturedAt
        self.state = state
        self.point = point
        self.history = history
        self.gpuState = gpuState
        self.gpu = gpu
        self.gpuDate = gpuDate
        self.processes = processes
        self.processesDate = processesDate
        self.processesFailed = processesFailed
        self.filesystems = filesystems
        self.filesystemsDate = filesystemsDate
        self.filesystemsFailed = filesystemsFailed
    }

}
