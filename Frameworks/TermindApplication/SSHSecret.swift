import Darwin
import Foundation

/// Centralized clearing for short-lived buffers that temporarily contain secrets.
public nonisolated enum SecretMemory {
    public static func clear(_ bytes: inout Data) {
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            _ = memset_s(base, raw.count, 0, raw.count)
        }
        bytes.removeAll(keepingCapacity: false)
    }
}

/// A one-shot UTF-8 secret used only while authenticating a connection.
///
/// Copies of an `SSHSecret` share one backing object. Consuming or clearing any
/// reference therefore invalidates every reference. The plaintext lives in one
/// explicitly owned, non-copy-on-write allocation that is overwritten before it
/// is released.
public nonisolated final class SSHSecret: @unchecked Sendable {
    public struct Consumed: Error, Sendable {
        public init() {}
    }

    private struct Storage {
        var pointer: UnsafeMutableRawPointer
        var count: Int

        func clearAndDeallocate() {
            _ = memset_s(pointer, count + 1, 0, count + 1)
            pointer.deallocate()
        }
    }

    private let lock = NSLock()
    private var storage: Storage?

    public convenience init(_ value: String) {
        var bytes = Data(value.utf8)
        self.init(consumingUTF8: &bytes)
    }

    /// Copies a freshly read UTF-8 buffer into wipeable ownership, then clears
    /// the source buffer before returning. The final allocation includes a NUL
    /// terminator without asking `Data` to grow or reallocate its plaintext.
    public init(consumingUTF8 bytes: inout Data) {
        let count = bytes.count
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: count + 1,
            alignment: MemoryLayout<UInt8>.alignment
        )
        if count > 0 {
            bytes.withUnsafeBytes { raw in
                guard let source = raw.baseAddress else { return }
                pointer.copyMemory(from: source, byteCount: count)
            }
        }
        pointer.storeBytes(of: UInt8(0), toByteOffset: count, as: UInt8.self)
        SecretMemory.clear(&bytes)
        storage = Storage(pointer: pointer, count: count)
    }

    deinit { clear() }

    public var isConsumed: Bool {
        lock.withLock { storage == nil }
    }

    /// Exposes the UTF-8 bytes once, including a trailing NUL outside `count`.
    /// The allocation is wiped before this method returns or throws.
    public func withUnsafeCStringAndConsume<Result>(
        _ body: (UnsafePointer<CChar>, Int) throws -> Result
    ) throws -> Result {
        let storage = try take()
        defer { storage.clearAndDeallocate() }
        return try body(
            UnsafePointer(storage.pointer.assumingMemoryBound(to: CChar.self)),
            storage.count
        )
    }

    /// Test support without extending the secret's lifetime.
    public func matches(_ value: String) -> Bool {
        let expected = Array(value.utf8)
        return lock.withLock {
            guard let storage, storage.count == expected.count else { return false }
            let bytes = UnsafeRawBufferPointer(start: storage.pointer, count: storage.count)
            return bytes.elementsEqual(expected)
        }
    }

    public func clear() {
        guard
            let storage = lock.withLock({ () -> Storage? in
                let value = storage
                self.storage = nil
                return value
            })
        else { return }
        storage.clearAndDeallocate()
    }

    private func take() throws -> Storage {
        try lock.withLock {
            guard let value = storage else { throw Consumed() }
            storage = nil
            return value
        }
    }
}

public nonisolated func == (lhs: SSHSecret, rhs: String) -> Bool {
    lhs.matches(rhs)
}

public nonisolated func == (lhs: String, rhs: SSHSecret) -> Bool {
    rhs.matches(lhs)
}
