import Darwin

nonisolated extension SecretMemory {
    public static func clear(_ pointer: UnsafeMutableRawPointer, count: Int) {
        guard count > 0 else { return }
        _ = memset_s(pointer, count, 0, count)
    }
}
