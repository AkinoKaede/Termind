/// Resolves connection capabilities without changing saved preferences.
/// The caller determines availability; this policy knows nothing about purchases or UI.
public nonisolated struct MultiConnectionPolicy: Equatable, Sendable {
    public var allowsMultipleConnections: Bool

    public init(allowsMultipleConnections: Bool) {
        self.allowsMultipleConnections = allowsMultipleConnections
    }

    public func sftpStrategy(_ saved: SFTPConcurrencyStrategy) -> SFTPConcurrencyStrategy {
        allowsMultipleConnections ? saved : .channelsOnly
    }

    public func sftpPreferences(_ saved: SFTPPreferences) -> SFTPPreferences {
        var effective = saved
        effective.strategy = sftpStrategy(saved.strategy)
        return effective
    }

    public func forwardingConnections(_ saved: Int) -> Int {
        allowsMultipleConnections ? Host.normalizedPortForwardingMaxConnections(saved) : 1
    }
}
