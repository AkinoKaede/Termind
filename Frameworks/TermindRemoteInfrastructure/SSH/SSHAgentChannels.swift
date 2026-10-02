import CSSH2
import Foundation
import TermindApplication

/// Accessed only on the owning SSH queue. Signing tasks never enter libssh2.
nonisolated final class SSHAgentChannels: @unchecked Sendable {
    private final class Channel: @unchecked Sendable {
        let pointer: OpaquePointer
        var decoder = SSHAgentProtocol()
        var output = Data()
        var offset = 0
        var task: Task<Void, Never>?
        var closing = false
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
    }
    private let provider: any SSHAgentForwarding
    private let queue: DispatchQueue
    private let wake: @Sendable () -> Void
    private var channels: [Channel] = []
    private var stopped = false

    init(provider: any SSHAgentForwarding, queue: DispatchQueue, wake: @escaping @Sendable () -> Void) {
        self.provider = provider
        self.queue = queue
        self.wake = wake
    }
    func accept(_ pointer: OpaquePointer) {
        let channel = Channel(pointer)
        channel.closing = stopped || channels.count >= 16
        channels.append(channel)
    }
    func shutdown() {
        guard !stopped else { return }
        stopped = true
        for channel in channels { channel.task?.cancel() }
        channels.removeAll()  // session_free owns the remaining libssh2 handles.
        let provider = provider
        Task { await provider.close() }
    }
    deinit { shutdown() }

    @discardableResult
    func advance(deadline: UInt64, permitsIO: () -> Bool = { true }) -> Bool {
        guard !stopped else { return false }
        var progressed = false
        let turn = channels
        if channels.count > 1 { channels.append(channels.removeFirst()) }
        for channel in turn {
            guard permitsIO(), DispatchTime.now().uptimeNanoseconds < deadline else { break }
            let drainedEOF =
                libssh2_channel_eof(channel.pointer) == 1
                && channel.task == nil && channel.output.isEmpty && channel.decoder.bytes.isEmpty
                && libssh2_poll_channel_read(channel.pointer, 0) == 0
            if channel.closing || drainedEOF {
                channel.task?.cancel()
                channel.closing = true
                let result = libssh2_channel_free(channel.pointer)
                if result != LIBSSH2_ERROR_EAGAIN {
                    channels.removeAll { $0 === channel }
                    progressed = true
                }
                continue
            }
            if channel.offset < channel.output.count {
                let written = channel.output.withUnsafeBytes {
                    libssh2_channel_write_ex(
                        channel.pointer, 0,
                        $0.baseAddress!.advanced(by: channel.offset).assumingMemoryBound(to: CChar.self),
                        $0.count - channel.offset)
                }
                if written > 0 {
                    channel.offset += written
                    progressed = true
                } else if written != LIBSSH2_ERROR_EAGAIN {
                    channel.closing = true
                }
                if channel.offset < channel.output.count { continue }
                channel.output.removeAll(keepingCapacity: false)
                channel.offset = 0
            }
            guard channel.task == nil else { continue }
            do {
                if let packet = try channel.decoder.next() {
                    start(packet, channel: channel)
                    progressed = true
                    continue
                }
                var bytes = [UInt8](
                    repeating: 0, count: min(8192, SSHAgentProtocol.maximumPacket + 4 - channel.decoder.bytes.count))
                let read = libssh2_channel_read_ex(channel.pointer, 0, &bytes, bytes.count)
                if read > 0 {
                    try channel.decoder.append(Data(bytes.prefix(read)))
                    progressed = true
                    if let packet = try channel.decoder.next() { start(packet, channel: channel) }
                } else if (read == 0 && libssh2_channel_eof(channel.pointer) == 1)
                    || (read != 0 && read != LIBSSH2_ERROR_EAGAIN)
                {
                    channel.closing = true
                    progressed = true
                }
            } catch { channel.closing = true }
        }
        return progressed
    }

    private func start(_ packet: Data, channel: Channel) {
        let provider = provider
        channel.task = Task { [weak self, weak channel] in
            let response = await SSHAgentProtocol.response(to: packet, provider: provider)
            guard !Task.isCancelled, let self, let channel else { return }
            self.queue.async { [weak self, weak channel] in
                guard let self, let channel, !self.stopped, !channel.closing else { return }
                channel.task = nil
                channel.output = response
                self.wake()
            }
        }
    }

    static let callback:
        @convention(c) (
            OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
        ) -> Void = { _, channel, abstract in
            guard let channel, let opaque = abstract?.pointee else { return }
            let buffer = Unmanaged<SSHConnectionBuffer>.fromOpaque(opaque).takeUnretainedValue()
            buffer.agentChannels?.accept(channel)
        }
}
