import Foundation

nonisolated struct SSHPTYSize: Equatable, Sendable {
    var columns: UInt16
    var rows: UInt16
    var widthPixels: UInt32 = 0
    var heightPixels: UInt32 = 0

    var isValid: Bool { columns > 0 && rows > 0 }
}

/// Owned exclusively by the SSH worker's serial queue. A viewport can arrive
/// before authentication finishes, or even before the first connect is queued.
nonisolated struct SSHPTYResizeState {
    private(set) var generation: UUID?
    private(set) var requestedSize: SSHPTYSize?
    private var appliedSize: SSHPTYSize?
    private var inFlightSize: SSHPTYSize?
    private var acceptsRequests = true

    mutating func beginConnection(columns: UInt16, rows: UInt16) -> UUID {
        let initial = generation == nil && acceptsRequests ? requestedSize : nil
        reset()
        let generation = UUID()
        self.generation = generation
        acceptsRequests = true
        requestedSize = initial ?? SSHPTYSize(columns: max(1, columns), rows: max(1, rows))
        return generation
    }

    mutating func request(_ size: SSHPTYSize) {
        guard acceptsRequests, size.isValid else { return }
        requestedSize = size
    }

    mutating func didCreatePTY(size: SSHPTYSize) {
        appliedSize = size
    }

    /// libssh2 retains its window-change packet on EAGAIN. Retry that exact
    /// size first; only after it succeeds may the newest request replace it.
    mutating func flush(send: (SSHPTYSize) -> Int32) -> Int32 {
        guard appliedSize != nil else { return 0 }
        while let size = inFlightSize ?? requestedSize, inFlightSize != nil || size != appliedSize {
            inFlightSize = size
            let result = send(size)
            guard result == 0 else { return result }
            appliedSize = size
            inFlightSize = nil
        }
        return 0
    }

    /// Drop only the failed packet, retaining any newer viewport. The same
    /// size may be requested again without closing the terminal connection.
    mutating func discardFailedRequest() {
        if requestedSize == inFlightSize { requestedSize = nil }
        inFlightSize = nil
    }

    mutating func reset() {
        generation = nil
        requestedSize = nil
        appliedSize = nil
        inFlightSize = nil
        acceptsRequests = false
    }
}
