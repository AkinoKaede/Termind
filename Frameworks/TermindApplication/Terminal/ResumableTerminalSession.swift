// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

public nonisolated enum ResumableTerminalState: Equatable, Sendable {
    case connecting, connected, recovering, suspended, ended, closed
    case failed
}

/// Opaque protocol state is sensitive: only the encrypted, device-local recovery store may persist it.
public nonisolated struct TerminalTransportCheckpoint: Codable, Sendable {
    public var version = 1
    public let transport: HostTerminalProtocol
    public let payload: Data

    public init(transport: HostTerminalProtocol, payload: Data) {
        self.transport = transport
        self.payload = payload
    }
}

public nonisolated protocol ResumableTerminalSession: Sendable {
    func write(_ data: Data) async throws
    func resize(columns: UInt16, rows: UInt16) async throws
    func suspend() async throws -> TerminalTransportCheckpoint
    func resume() async throws
    func retryNow() async throws
    func close() async
}
