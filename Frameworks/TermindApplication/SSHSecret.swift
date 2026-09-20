import Darwin
import Foundation

/// A one-shot UTF-8 secret used only while authenticating a connection.
///
/// Copies of an `SSHSecret` share one backing object. Consuming or clearing any
/// reference therefore invalidates every reference instead of creating another
/// plaintext lifetime through Swift value copying. The backing bytes are
/// overwritten with `memset_s` after use and again from `deinit` as a
/// defensive fallback.
public nonisolated final class SSHSecret: @unchecked Sendable {
    public struct Consumed: Error, Sendable {
        public init() {}
    }

    private let lock = NSLock()
    private var storage: Data?

    public init(_ value: String) {
        var bytes = Data(value.utf8)
        bytes.append(0)
        storage = bytes
    }

    /// Transfers a freshly read UTF-8 buffer into wipeable ownership without
    /// first materializing an immutable Swift `String`.
    public init(consumingUTF8 bytes: inout Data) {
        bytes.append(0)
        storage = bytes
        bytes = Data()
    }

    deinit { clear() }

    public var isConsumed: Bool {
        lock.withLock { storage == nil }
    }

    /// Exposes the UTF-8 bytes once, including a trailing NUL outside `count`.
    /// The memory is wiped before this method returns or throws.
    public func withUnsafeCStringAndConsume<Result>(
        _ body: (UnsafePointer<CChar>, Int) throws -> Result
    ) throws -> Result {
        var bytes = try take()
        defer { Self.wipe(&bytes) }
        return try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                throw Consumed()
            }
            return try body(base, max(0, raw.count - 1))
        }
    }

    /// Test and diagnostic support without extending the secret's lifetime.
    /// Production authentication should use `withUnsafeCStringAndConsume`.
    public func matches(_ value: String) -> Bool {
        let expected = Array(value.utf8)
        return lock.withLock {
            guard let storage, storage.count == expected.count + 1 else { return false }
            return storage.dropLast().elementsEqual(expected)
        }
    }

    public func clear() {
        guard
            var bytes = lock.withLock({ () -> Data? in
                let value = storage
                storage = nil
                return value
            })
        else { return }
        Self.wipe(&bytes)
    }

    private func take() throws -> Data {
        try lock.withLock {
            guard let value = storage else { throw Consumed() }
            storage = nil
            return value
        }
    }

    private static func wipe(_ bytes: inout Data) {
        bytes.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            _ = memset_s(base, raw.count, 0, raw.count)
        }
        bytes.removeAll(keepingCapacity: false)
    }
}

public nonisolated func == (lhs: SSHSecret, rhs: String) -> Bool {
    lhs.matches(rhs)
}

public nonisolated func == (lhs: String, rhs: SSHSecret) -> Bool {
    rhs.matches(lhs)
}
