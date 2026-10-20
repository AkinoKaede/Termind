// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Observation
import TermindDomain

@MainActor
public protocol LocalHostDiscovering: AnyObject {
    var connectionProtocol: LocalDiscoveryProtocol { get }
    func discover() async throws -> [DiscoveredLocalHost]
}

public nonisolated enum LocalDiscoveryError: Error {
    case unavailable
    case permissionDenied
    case failed
}

@MainActor
@Observable
public final class LocalDiscoveryModel {
    public enum Phase { case idle, scanning, finished, unavailable, permissionDenied, failed }
    public private(set) var phase = Phase.idle
    public private(set) var hosts: [DiscoveredLocalHost] = []
    public var connectionProtocol: LocalDiscoveryProtocol { service.connectionProtocol }
    private let service: any LocalHostDiscovering
    private var task: Task<Void, Never>?
    private var generation = UUID()

    public init(service: any LocalHostDiscovering) { self.service = service }

    public func scan() {
        cancel()
        hosts = []
        phase = .scanning
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let hosts = try await service.discover()
                try Task.checkCancellation()
                guard token == generation else { return }
                self.hosts = DiscoveredLocalHost.merged(hosts)
                phase = .finished
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                switch error {
                case LocalDiscoveryError.unavailable: phase = .unavailable
                case LocalDiscoveryError.permissionDenied: phase = .permissionDenied
                default: phase = .failed
                }
            }
            task = nil
        }
    }

    public func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        if phase == .scanning { phase = .idle }
    }
}
