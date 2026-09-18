import Foundation
import TermindApplication

/// A browser and its queued transfers share ownership of one authenticated connection.
/// Extra connections are always opened without interaction, using this generation's snapshot.
@MainActor
public final class SFTPTransferSession {
    public let id = UUID()
    public let configuration: SSHConnectionConfiguration
    private var clientFactory: SFTPTransferCoordinator.ClientFactory
    private var primary: (any SFTPClientProtocol)?
    private var ownerAttached = true
    private var transfers: Set<UUID> = []
    private var activeSlots = 0
    private let prefersPrimary: Bool
    private var primaryBusy = false
    private var probing = false
    private enum Capability { case unknown, parallel, serial }
    private var capability = Capability.unknown
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var availabilityChanged: (() -> Void)?

    public init(
        configuration: SSHConnectionConfiguration, client: any SFTPClientProtocol,
        wasOpenedSilently: Bool = false,
        clientFactory: @escaping SFTPTransferCoordinator.ClientFactory = { SFTPClient() }
    ) {
        self.configuration = configuration
        self.primary = client
        self.clientFactory = clientFactory
        self.prefersPrimary = wasOpenedSilently
        self.capability = wasOpenedSilently ? .parallel : .unknown
    }

    deinit {
        if let primary { Task { await primary.disconnect() } }
    }

    var canStartTransfer: Bool { capability == .parallel || activeSlots == 0 }

    func configureClientFactory(_ factory: @escaping SFTPTransferCoordinator.ClientFactory) {
        clientFactory = factory
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

    /// A failed transport is never installed into a replacement browser generation.
    public func retire() async {
        ownerAttached = false
        let old = primary
        primary = nil
        capability = .unknown
        wakeWaiters()
        await old?.disconnect()
    }

    func acquire(cancellation: TransferCancellationToken? = nil) async throws -> SFTPTransferLease {
        try checkCancellation(cancellation)
        while probing { try await waitForPrimary(cancellation: cancellation) }
        if capability != .serial, primary != nil, !(prefersPrimary && !primaryBusy) {
            let isProbe = capability == .unknown
            if isProbe { probing = true }
            defer {
                if isProbe {
                    probing = false
                    wakeWaiters()
                }
            }
            do {
                let client = try await openSilently(cancellation: cancellation)
                if capability != .serial { capability = .parallel }
                availabilityChanged?()
                return SFTPTransferLease(client: client) { await client.disconnect() }
            } catch {
                try checkCancellation(cancellation)
                if error is CancellationError { throw error }
                if let failure = error as? SFTPError, case .cancelled = failure { throw failure }
                capability = .serial
                availabilityChanged?()
            }
        }
        while primaryBusy {
            try await waitForPrimary(cancellation: cancellation)
        }
        try checkCancellation(cancellation)
        primaryBusy = true
        do {
            let client: any SFTPClientProtocol
            if let primary {
                client = primary
            } else {
                client = try await openSilently(cancellation: cancellation)
                primary = client
                capability = .unknown
            }
            return SFTPTransferLease(client: client) { [self] in
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

    private func openSilently(cancellation: TransferCancellationToken?) async throws -> any SFTPClientProtocol {
        let client = clientFactory()
        let request = SSHConnectionRequest(configuration: configuration, interactionPolicy: .forbidden)
            .enforcingInteractionPolicy()
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
final class SFTPTransferLease {
    let client: any SFTPClientProtocol
    private var release: (() async -> Void)?

    init(client: any SFTPClientProtocol, release: @escaping () async -> Void) {
        self.client = client
        self.release = release
    }

    func disconnect() async {
        let action = release
        release = nil
        await action?()
    }
}
