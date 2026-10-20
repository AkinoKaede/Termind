// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication

public nonisolated enum SFTPTransferPrimaryRole: Hashable, Sendable {
    /// A browser control channel that data work should avoid while alternatives exist.
    case control
    /// An independent preflight connection that can be donated to the first transfer.
    case donatedConnection
    /// The authenticated connection belonging to a PTY channel, used only after independent preflight failed.
    case ptyConnectionFallback
}

/// A browser and its queued transfers share ownership of one authenticated connection.
/// The admitted topology decides between sibling channels and additional connections;
/// additional connections are always opened without interaction from this generation's snapshot.
@MainActor
public final class SFTPTransferContext {
    public let id = UUID()
    public let snapshot: SSHAdditionalConnectionSnapshot
    private weak var hostStore: (any RemoteSessionHostStore)?
    private var clientFactory: SFTPTransferCoordinator.ClientFactory
    private var primary: (any SFTPChannelProtocol)?
    private var ownerAttached = true
    private var transfers: Set<UUID> = []
    private var activeSlots = 0
    private let primaryRole: SFTPTransferPrimaryRole
    private var primaryBusy = false
    private var probing = false
    private enum Capability { case unknown, connections, channels }
    private var capability = Capability.unknown
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var availabilityChanged: (() -> Void)?

    public init(
        snapshot: SSHAdditionalConnectionSnapshot, hostStore: (any RemoteSessionHostStore)? = nil,
        channel: any SFTPChannelProtocol,
        primaryRole: SFTPTransferPrimaryRole = .control,
        clientFactory: @escaping SFTPTransferCoordinator.ClientFactory = { SFTPClient() }
    ) {
        self.snapshot = snapshot
        self.hostStore = hostStore
        self.primary = channel
        self.clientFactory = clientFactory
        self.primaryRole = primaryRole
        self.capability = primaryRole == .ptyConnectionFallback ? .channels : .unknown
    }

    deinit {
        if let primary { Task { await primary.disconnect() } }
    }

    func configureClientFactory(_ factory: @escaping SFTPTransferCoordinator.ClientFactory) {
        clientFactory = factory
    }

    public func configureHostStore(_ store: any RemoteSessionHostStore) {
        hostStore = store
    }

    func suspendTransfer(_ id: UUID) {
        transfers.remove(id)
        Task { await closeIfUnused() }
    }

    func retainTransfer(_ id: UUID) { transfers.insert(id) }

    func releaseTransfer(_ id: UUID) async {
        transfers.remove(id)
        await closeIfUnused()
    }

    func reserveSlot() { activeSlots += 1 }

    func releaseSlot() {
        activeSlots -= 1
        wakeWaiters()
    }

    /// Closing a pane relinquishes its ownership; queued jobs still own the connection.
    public func releaseOwner() async {
        ownerAttached = false
        await closeIfUnused()
    }

    /// A failed connection is never installed into a replacement browser generation.
    public func retire() async {
        ownerAttached = false
        let old = primary
        primary = nil
        capability = .unknown
        wakeWaiters()
        await old?.disconnect()
    }

    func acquire(
        mode: SSHChannelSchedulingMode,
        cancellation: TransferCancellationToken? = nil
    ) async throws -> SFTPChannelLease {
        try checkCancellation(cancellation)
        while probing { try await waitForPrimary(cancellation: cancellation) }
        if shouldLeasePrimary(mode: mode), let lease = leasePrimaryIfAvailable() {
            return lease
        }
        if mode == .channelsOnly, let primary {
            do {
                let channel = try await primary.openSiblingChannel()
                try checkCancellation(cancellation)
                return SFTPChannelLease(channel: channel) { await channel.disconnect() }
            } catch {
                try checkCancellation(cancellation)
                if error is CancellationError { throw error }
                if let failure = error as? SFTPError, case .cancelled = failure { throw failure }
                // A server may accept only the browser's original SFTP
                // subsystem. Keep the channel-only connection contract and
                // serialize this lease on that primary rather than opening a
                // second SSH connection or pausing the transfer.
            }
        }
        if mode == .connectionsPreferred, capability != .channels, primary != nil,
            primaryRole != .donatedConnection || primaryBusy
        {
            let isProbe = capability == .unknown
            if isProbe { probing = true }
            defer {
                if isProbe {
                    probing = false
                    wakeWaiters()
                }
            }
            do {
                let channel = try await openSilently(cancellation: cancellation)
                if capability != .channels { capability = .connections }
                availabilityChanged?()
                return SFTPChannelLease(channel: channel) { await channel.disconnect() }
            } catch {
                try checkCancellation(cancellation)
                if error is CancellationError { throw error }
                if let failure = error as? SFTPError, case .cancelled = failure { throw failure }
                capability = .channels
                availabilityChanged?()
            }
        }
        if mode == .connectionsPreferred, capability == .channels, let primary {
            if primaryRole == .ptyConnectionFallback, let lease = leasePrimaryIfAvailable() {
                return lease
            }
            do {
                try checkCancellation(cancellation)
                let channel = try await primary.openSiblingChannel()
                try checkCancellation(cancellation)
                availabilityChanged?()
                return SFTPChannelLease(channel: channel) { await channel.disconnect() }
            } catch {
                try checkCancellation(cancellation)
                if error is CancellationError { throw error }
                if let failure = error as? SFTPError, case .cancelled = failure { throw failure }
            }
        }
        while primaryBusy {
            try await waitForPrimary(cancellation: cancellation)
        }
        try checkCancellation(cancellation)
        primaryBusy = true
        do {
            let channel: any SFTPChannelProtocol
            if let primary {
                channel = primary
            } else {
                channel = try await openSilently(cancellation: cancellation)
                primary = channel
                capability = .unknown
            }
            return SFTPChannelLease(channel: channel) { [self] in
                primaryBusy = false
                wakeWaiters()
                await closeIfUnused()
                availabilityChanged?()
            }
        } catch {
            primaryBusy = false
            wakeWaiters()
            throw error
        }
    }

    private func shouldLeasePrimary(mode: SSHChannelSchedulingMode) -> Bool {
        switch primaryRole {
        case .control:
            false
        case .donatedConnection:
            !primaryBusy
        case .ptyConnectionFallback:
            mode == .channelsOnly && !primaryBusy
        }
    }

    private func leasePrimaryIfAvailable() -> SFTPChannelLease? {
        guard !primaryBusy, let primary else { return nil }
        primaryBusy = true
        return SFTPChannelLease(channel: primary) { [self] in
            primaryBusy = false
            wakeWaiters()
            await closeIfUnused()
            availabilityChanged?()
        }
    }

    private func openSilently(cancellation: TransferCancellationToken?) async throws -> any SFTPChannelProtocol {
        guard let hostStore else { throw SFTPError.notConnected }
        let client = clientFactory()
        let request = try hostStore.additionalConnectionRequest(from: snapshot)
        let opening = Task {
            try await client.connect(using: request, progress: nil, connectionFailure: nil)
        }
        let observer = cancellation?.observeCancellation { opening.cancel() }
        defer { if let observer { cancellation?.removeObserver(observer) } }
        do {
            try await withTaskCancellationHandler {
                try await opening.value
                try checkCancellation(cancellation)
            } onCancel: {
                opening.cancel()
            }
            return client
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private func waitForPrimary(cancellation: TransferCancellationToken?) async throws {
        let id = UUID()
        let observer = cancellation?.observeCancellation { [weak self] in
            Task { @MainActor in self?.cancelWaiter(id) }
        }
        defer { if let observer { cancellation?.removeObserver(observer) } }
        try await withTaskCancellationHandler {
            try checkCancellation(cancellation)
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func wakeWaiters() {
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    private func checkCancellation(_ cancellation: TransferCancellationToken?) throws {
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }
    }

    private func closeIfUnused() async {
        guard !ownerAttached, transfers.isEmpty, !primaryBusy, activeSlots == 0 else { return }
        let old = primary
        primary = nil
        capability = .unknown
        await old?.disconnect()
    }
}

@MainActor
final class SFTPChannelLease {
    let channel: any SFTPChannelProtocol
    private var release: (() async -> Void)?

    init(channel: any SFTPChannelProtocol, release: @escaping () async -> Void) {
        self.channel = channel
        self.release = release
    }

    func disconnect() async {
        let action = release
        release = nil
        await action?()
    }
}
