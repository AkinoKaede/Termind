import CSSH2

/// Queue-confined startup sizing. A PTY request and a process request each retain
/// their own arguments across EAGAIN; newer geometry is flushed between them.
nonisolated struct SSHPTYStartupSizing {
    private var requestedSize: SSHPTYSize?
    private var processRequestStarted = false

    mutating func requestPTY(
        resize: inout SSHPTYResizeState, send: (SSHPTYSize) -> Int32
    ) -> Int32 {
        if requestedSize == nil { requestedSize = resize.requestedSize }
        guard let size = requestedSize else { return LIBSSH2_ERROR_CHANNEL_CLOSED }
        let result = send(size)
        if result == 0 { resize.didCreatePTY(size: size) }
        return result
    }

    mutating func startProcess(
        resize: inout SSHPTYResizeState,
        sendResize: (SSHPTYSize) -> Int32,
        start: () -> Int32
    ) -> Int32 {
        if !processRequestStarted {
            let result = resize.flush(send: sendResize)
            guard result == 0 else { return result }
            processRequestStarted = true
        }
        return start()
    }
}
