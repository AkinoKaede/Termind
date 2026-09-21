import CSSH2
import Foundation
import TermindDomain

/// Owns every SFTP subsystem channel attached to one non-blocking SSH connection.
///
/// The terminal and Agent workers keep their feature-specific PTY/exec pumps,
/// while this type centralizes the shared channel lifecycle and bounded
/// libssh2 turns. All mutable state is confined to the SSH owner's queue.
nonisolated final class SSHMultiplexedSFTPChannelOwner: @unchecked Sendable {
    struct Context: @unchecked Sendable {
        var connection: SSHAuthenticatedConnection
        var buffer: SSHConnectionBuffer
        var channelBudget: SSHChannelBudget
        var charset: RemoteCharset
    }

    private struct OwnedChannel {
        var pointer: OpaquePointer
        var lease: SSHChannelLease
    }

    typealias ContextProvider = @Sendable () -> Context?
    typealias EventUpdater = @Sendable (OpaquePointer, SSHConnectionBuffer) -> Void

    private let queue: DispatchQueue
    private let context: ContextProvider
    private let updateEvents: EventUpdater
    private let didCloseLastChannel: @Sendable () -> Void
    private let identity = UUID()
    private var channels: [UUID: OwnedChannel] = [:]
    private var opening = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        queue: DispatchQueue,
        context: @escaping ContextProvider,
        updateEvents: @escaping EventUpdater,
        didCloseLastChannel: @escaping @Sendable () -> Void = {}
    ) {
        self.queue = queue
        self.context = context
        self.updateEvents = updateEvents
        self.didCloseLastChannel = didCloseLastChannel
    }

    func openChannel() async throws -> any SFTPChannelProtocol {
        let driver = SFTPChannelDriver(
            identity: identity,
            open: { [weak self] in
                guard let self else { throw SFTPError.notConnected }
                return try await self.createChannel()
            },
            close: { [weak self] id in await self?.closeChannel(id) },
            perform: { [weak self] id, operation in
                guard let self else { throw SFTPError.notConnected }
                return try await self.perform(id, operation)
            })
        let charset = try await queue.perform { [self] in
            guard let context = context() else { throw SFTPError.notConnected }
            return context.charset
        }
        return try await SFTPChannel.open(using: driver, charset: charset)
    }

    /// Called by the enclosing SSH owner while already executing on `queue`.
    func closeAllOnQueue() {
        for channel in channels.values {
            _ = libssh2_sftp_shutdown(channel.pointer)
            channel.lease.release()
        }
        channels.removeAll()
    }

    var isEmptyOnQueue: Bool { channels.isEmpty }

    private func createChannel() async throws -> UUID {
        await reserveOpen()
        defer { releaseOpen() }
        let budget = try await queue.perform { [self] in
            guard let context = context() else { throw SFTPError.notConnected }
            return context.channelBudget
        }
        let lease = try await budget.acquire()
        var retainedLease = false
        defer { if !retainedLease { lease.release() } }
        let id = UUID()
        while true {
            try Task.checkCancellation()
            let attempt: SFTPChannelAttempt<Void> = try await queue.perform { [self] in
                guard let context = context() else { throw SFTPError.notConnected }
                context.buffer.beginPass(
                    deadline: DispatchTime.now().uptimeNanoseconds
                        + SSHForwardingTuning.current.sliceNanoseconds)
                try context.buffer.flush(socket: context.connection.byteTransport.socket)
                if context.buffer.isBackpressured { return .again }
                guard let sftp = libssh2_sftp_init(context.connection.libssh2Session) else {
                    if libssh2_session_last_errno(context.connection.libssh2Session) == LIBSSH2_ERROR_EAGAIN {
                        return .again
                    }
                    throw SSHConnectionOpener.connectionError(
                        context.connection.libssh2Session, prefix: "Unable to start SFTP")
                }
                channels[id] = OwnedChannel(pointer: sftp, lease: lease)
                do {
                    try context.buffer.flush(socket: context.connection.byteTransport.socket)
                } catch {
                    channels[id] = nil
                    _ = libssh2_sftp_shutdown(sftp)
                    throw error
                }
                updateEvents(context.connection.libssh2Session, context.buffer)
                return .value(())
            }
            if case .value = attempt {
                retainedLease = true
                do {
                    try Task.checkCancellation()
                    return id
                } catch {
                    await closeChannel(id)
                    throw error
                }
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func reserveOpen() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if opening {
                    openWaiters.append(continuation)
                } else {
                    opening = true
                    continuation.resume()
                }
            }
        }
    }

    private func releaseOpen() {
        queue.async { [self] in
            if openWaiters.isEmpty {
                opening = false
            } else {
                openWaiters.removeFirst().resume()
            }
        }
    }

    private func closeChannel(_ id: UUID) async {
        while true {
            let attempt: SFTPChannelAttempt<Void> =
                (try? await queue.perform { [self] in
                    guard let owned = channels[id] else { return .value(()) }
                    guard let context = context() else {
                        channels[id] = nil
                        owned.lease.release()
                        if channels.isEmpty { didCloseLastChannel() }
                        return .value(())
                    }
                    context.buffer.beginPass(
                        deadline: DispatchTime.now().uptimeNanoseconds
                            + SSHForwardingTuning.current.sliceNanoseconds)
                    do {
                        try context.buffer.flush(socket: context.connection.byteTransport.socket)
                    } catch {
                        channels[id] = nil
                        owned.lease.release()
                        if channels.isEmpty { didCloseLastChannel() }
                        return .value(())
                    }
                    let result = libssh2_sftp_shutdown(owned.pointer)
                    if result == LIBSSH2_ERROR_EAGAIN { return .again }
                    channels[id] = nil
                    owned.lease.release()
                    try context.buffer.flush(socket: context.connection.byteTransport.socket)
                    updateEvents(context.connection.libssh2Session, context.buffer)
                    if channels.isEmpty { didCloseLastChannel() }
                    return .value(())
                }) ?? .value(())
            if case .value = attempt { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func perform(
        _ id: UUID, _ operation: @escaping SFTPChannelDriver.RawOperation
    ) async throws -> SFTPChannelValue {
        while true {
            try Task.checkCancellation()
            let attempt = try await queue.perform { [self] in
                guard let owned = channels[id], let context = context() else {
                    throw SFTPError.notConnected
                }
                context.buffer.beginPass(
                    deadline: DispatchTime.now().uptimeNanoseconds
                        + SSHForwardingTuning.current.sliceNanoseconds)
                try context.buffer.flush(socket: context.connection.byteTransport.socket)
                if context.buffer.isBackpressured { return SFTPChannelAnyAttempt.again }
                let result = try operation(context.connection.libssh2Session, owned.pointer)
                try context.buffer.flush(socket: context.connection.byteTransport.socket)
                updateEvents(context.connection.libssh2Session, context.buffer)
                return result
            }
            switch attempt {
            case .value(let value): return value
            case .again: try await Task.sleep(for: .milliseconds(2))
            }
        }
    }
}
