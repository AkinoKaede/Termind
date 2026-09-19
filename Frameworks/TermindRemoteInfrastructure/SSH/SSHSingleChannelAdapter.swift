import Foundation

/// Lifecycle and admission adapter for features that deliberately own one SSH
/// connection and at most one active Channel. It has no topology selection or
/// fallback policy; callers that need concurrency use `SSHChannelSchedulingMode`.
public actor SSHSingleChannelAdapter<Channel: Sendable> {
    public nonisolated let channel: Channel
    private let close: @Sendable (Channel) async -> Void
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(channel: Channel, close: @escaping @Sendable (Channel) async -> Void) {
        self.channel = channel
        self.close = close
    }

    /// Serializes short-lived Channels such as Metrics exec requests. A user
    /// SSH session instead keeps its one PTY Channel installed on `channel` and
    /// uses the Adapter for common lifetime/teardown only.
    public func withChannel<Value: Sendable>(
        _ operation: @escaping @Sendable (Channel) async throws -> Value
    ) async throws -> Value {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer {
            if waiters.isEmpty {
                busy = false
            } else {
                waiters.removeFirst().resume()
            }
        }
        return try await operation(channel)
    }

    public func disconnect() async { await close(channel) }
}
