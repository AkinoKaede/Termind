// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

@MainActor
public protocol OutboxStore: AnyObject {
    func nextReady(at date: Date) throws -> OutboxJob?
    func markRunning(_ id: OutboxJob.ID) throws
    func markSucceeded(_ id: OutboxJob.ID) throws
    func markFailed(_ id: OutboxJob.ID, error: String, retryAt: Date?) throws
    func resetInterruptedJobs() throws
}

public protocol OutboxEventHandler: AnyObject {
    nonisolated var handlerID: String { get }
    func handle(type: String, payload: Data, eventID: UUID) async throws
}
