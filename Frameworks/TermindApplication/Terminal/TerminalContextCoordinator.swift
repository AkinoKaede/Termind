// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Observation
import TermindDomain

public nonisolated enum TerminalRuntimeError: Error, Sendable {
    case capacityUnavailable, unsupported, invalidResponse, staleContext
}

/// Implementations may only use the terminal's existing authenticated transport.
public nonisolated protocol TerminalRuntimeAdapter: Sendable {
    func inspect(terminal: String) async throws -> TerminalRuntimeUpdate
}

@MainActor @Observable
public final class TerminalContextCoordinator {
    public struct Ticket: Equatable, Sendable {
        public let generation: UUID
        public let revision: UInt64
        public let context: TerminalContextIdentity
    }

    public private(set) var generation = UUID()
    public private(set) var revision: UInt64 = 0
    public private(set) var status: TerminalRuntimeUpdate.Status = .unknown
    public private(set) var active: TerminalShellContext?
    public private(set) var contexts: [TerminalContextIdentity: TerminalShellContext] = [:]
    public private(set) var clientIdentity: String?
    public private(set) var backend: SessionPersistenceBackendID?
    public private(set) var issue: TerminalRuntimeIssue?
    private var sequences: [TerminalContextIdentity: UInt64] = [:]
    private var running: Set<TerminalContextIdentity> = []
    private var inspectionID: UUID?

    public init() {}

    public var directory: String? {
        // The shell's last reported cwd remains useful while a command owns the
        // foreground. Capability tickets, not path display, gate live operations.
        active?.directory
    }

    public func reset() {
        generation = UUID()
        revision &+= 1
        status = .unknown
        active = nil
        clientIdentity = nil
        backend = nil
        issue = nil
        contexts.removeAll()
        sequences.removeAll()
        running.removeAll()
        inspectionID = nil
    }

    public func noteInput() { revision &+= 1 }

    public func ticket(requiring capability: TerminalContextCapabilities) -> Ticket? {
        guard let active, active.promptReady, active.capabilities.contains(capability) else { return nil }
        return Ticket(generation: generation, revision: revision, context: active.identity)
    }

    public func isCurrent(_ ticket: Ticket, requiring capability: TerminalContextCapabilities) -> Bool {
        self.ticket(requiring: capability) == ticket
    }

    public func refresh(using adapter: any TerminalRuntimeAdapter, terminal: String) async throws {
        let id = UUID()
        inspectionID = id
        let generation = generation
        let revision = revision
        let update = try await adapter.inspect(terminal: terminal)
        try Task.checkCancellation()
        guard inspectionID == id, self.generation == generation, self.revision == revision else {
            throw TerminalRuntimeError.staleContext
        }
        receive(update, generation: generation)
    }

    /// Returns only new, contiguous events. A snapshot never invents a command start.
    @discardableResult
    public func receive(_ update: TerminalRuntimeUpdate, generation expected: UUID) -> [TerminalContextEvent] {
        guard expected == generation else { return [] }
        if let active = update.active,
            let snapshot = update.contexts.first(where: { $0.identity == active }),
            let last = sequences[active], snapshot.sequence < last
        {
            return []
        }
        var accepted: [TerminalContextEvent] = []
        var interrupted: Set<TerminalContextIdentity> = []
        if update.status == .multiplexer {
            for context in update.contexts where sequences[context.identity] == nil {
                sequences[context.identity] = context.sequence
            }
        }
        for event in update.events {
            guard let source = update.contexts.first(where: { $0.identity == event.context }),
                event.sequence <= source.sequence
            else { continue }
            let last = sequences[event.context]
            guard last == nil || event.sequence > last! else { continue }
            let contiguous = last.map { $0 < UInt64.max && event.sequence == $0 + 1 } ?? (event.sequence == 1)
            if !contiguous {
                running.remove(event.context)
                interrupted.insert(event.context)
            }
            sequences[event.context] = event.sequence
            switch event.payload {
            case .commandStarted:
                guard source.capabilities.contains(.commandLifecycle) else { continue }
                running.insert(event.context)
                accepted.append(event)
            case .commandFinished:
                guard source.capabilities.contains(.commandLifecycle) else { continue }
                if running.remove(event.context) != nil, contiguous { accepted.append(event) }
            default:
                accepted.append(event)
            }
        }
        let next = Dictionary(update.contexts.map { ($0.identity, $0) }, uniquingKeysWith: { _, new in new })
        for context in update.contexts {
            // Establish a high-water mark when joining an already-running shell.
            if sequences[context.identity] == nil { sequences[context.identity] = context.sequence }
        }
        let nextActive =
            update.status == .ordinary || update.status == .multiplexer ? update.active.flatMap { next[$0] } : nil
        let activeInteractionChanged = accepted.contains { event in
            guard event.context == nextActive?.identity || event.context == active?.identity else { return false }
            if case .draft = event.payload { return false }
            return true
        }
        if status != update.status || clientIdentity != update.clientIdentity
            || backend != update.backend || issue != update.issue
            || active?.identity != nextActive?.identity || active?.promptReady != nextActive?.promptReady
            || active?.directory != nextActive?.directory || active?.capabilities != nextActive?.capabilities
            || active?.directorySource != nextActive?.directorySource
            || activeInteractionChanged
            || nextActive.map({ interrupted.contains($0.identity) }) == true
        {
            revision &+= 1
        }
        status = update.status
        clientIdentity = update.clientIdentity
        backend = update.backend
        issue = update.issue
        active = nextActive
        contexts = next
        if update.status == .multiplexer {
            running = running.filter { $0.backend == "shell" || next[$0] != nil }
        }
        return accepted
    }
}
