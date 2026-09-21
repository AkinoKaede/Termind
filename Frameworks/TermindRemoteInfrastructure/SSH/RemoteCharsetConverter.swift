import Darwin
import Foundation
import TermindDomain

nonisolated extension RemoteCharset {
    fileprivate var iconvName: String {
        switch self {
        case .utf8: "UTF-8"
        case .gb18030: "GB18030"
        case .big5: "BIG5"
        case .shiftJIS: "SHIFT_JIS"
        case .eucJP: "EUC-JP"
        case .eucKR: "EUC-KR"
        case .isoLatin1: "ISO-8859-1"
        case .windows1252: "WINDOWS-1252"
        }
    }
}

public nonisolated struct RemoteCharsetConversionError: LocalizedError, Sendable {
    public enum Direction: Sendable { case encoding, decoding }

    public var charset: RemoteCharset
    public var direction: Direction

    public init(charset: RemoteCharset, direction: Direction) {
        self.charset = charset
        self.direction = direction
    }

    public var errorDescription: String? {
        switch direction {
        case .encoding:
            String(localized: "Text cannot be represented using \(charset.displayName).")
        case .decoding:
            String(localized: "Received text is not valid \(charset.displayName).")
        }
    }
}

/// A stateful, strict iconv adapter. Callers choose whether malformed source
/// bytes fail the operation or are discarded so an interactive stream can stay open.
public nonisolated final class RemoteCharsetStreamConverter: @unchecked Sendable {
    public enum Direction: Sendable { case encoding, decoding }

    public struct Output: Sendable {
        public var data: Data
        public var rejectedInput: Bool
    }

    private struct Conversion {
        var output: Data
        var remainder: Data
        var rejectedInput: Bool
    }

    public let charset: RemoteCharset
    public let direction: Direction

    private let descriptor: iconv_t
    private let lock = NSLock()
    private var pending = Data()

    public init(charset: RemoteCharset, direction: Direction) throws {
        self.charset = charset
        self.direction = direction
        let source = direction == .encoding ? RemoteCharset.utf8.iconvName : charset.iconvName
        let destination = direction == .encoding ? charset.iconvName : RemoteCharset.utf8.iconvName
        descriptor = iconv_open(destination, source)
        guard descriptor != iconv_t(bitPattern: -1) else {
            throw RemoteCharsetConversionError(charset: charset, direction: errorDirection)
        }
    }

    deinit { iconv_close(descriptor) }

    /// Converts one stream fragment. Incomplete source characters are retained.
    /// With recovery enabled, invalid source bytes are discarded without emitting
    /// replacement characters and `rejectedInput` is set.
    public func convert(_ data: Data, recoveringInvalidInput: Bool = false) throws -> Output {
        try lock.withLock {
            try convertLocked(data, recoveringInvalidInput: recoveringInvalidInput)
        }
    }

    private func convertLocked(_ data: Data, recoveringInvalidInput: Bool) throws -> Output {
        var source = pending
        source.append(data)
        pending.removeAll(keepingCapacity: true)
        do {
            let converted = try convert(source, final: false, recoveringInvalidInput: recoveringInvalidInput)
            pending = converted.remainder
            return Output(data: converted.output, rejectedInput: converted.rejectedInput)
        } catch {
            pending.removeAll(keepingCapacity: false)
            reset()
            throw error
        }
    }

    /// Finishes the stream. An incomplete trailing character is rejected.
    public func finish(recoveringInvalidInput: Bool = false) throws -> Output {
        try lock.withLock {
            try finishLocked(recoveringInvalidInput: recoveringInvalidInput)
        }
    }

    private func finishLocked(recoveringInvalidInput: Bool) throws -> Output {
        defer {
            pending.removeAll(keepingCapacity: false)
            reset()
        }
        let converted = try convert(pending, final: true, recoveringInvalidInput: recoveringInvalidInput)
        return Output(data: converted.output, rejectedInput: converted.rejectedInput)
    }

    public static func encode(_ value: String, charset: RemoteCharset) throws -> Data {
        let converter = try RemoteCharsetStreamConverter(charset: charset, direction: .encoding)
        var output = try converter.convert(Data(value.utf8)).data
        output.append(try converter.finish().data)
        return output
    }

    public static func decode(_ data: Data, charset: RemoteCharset) throws -> String {
        let converter = try RemoteCharsetStreamConverter(charset: charset, direction: .decoding)
        var output = try converter.convert(data).data
        output.append(try converter.finish().data)
        guard let value = String(data: output, encoding: .utf8) else {
            throw RemoteCharsetConversionError(charset: charset, direction: .decoding)
        }
        return value
    }

    private var errorDirection: RemoteCharsetConversionError.Direction {
        direction == .encoding ? .encoding : .decoding
    }

    private func convert(
        _ data: Data, final: Bool, recoveringInvalidInput: Bool
    ) throws -> Conversion {
        var bytes = Array(data)
        defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var output = Data()
        var rejectedInput = false
        var remainder = Data()

        try bytes.withUnsafeMutableBytes { rawBuffer in
            var input = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self)
            var inputCount = rawBuffer.count

            while inputCount > 0 {
                var chunk = [CChar](repeating: 0, count: max(256, min(64 * 1024, inputCount * 4 + 16)))
                let result: Int = chunk.withUnsafeMutableBufferPointer { buffer in
                    var destination = buffer.baseAddress
                    var destinationCount = buffer.count
                    let result = iconv(descriptor, &input, &inputCount, &destination, &destinationCount)
                    output.append(
                        Data(bytes: buffer.baseAddress!, count: buffer.count - destinationCount)
                    )
                    return result
                }
                if result != -1 { continue }
                switch errno {
                case E2BIG:
                    continue
                case EINVAL where !final:
                    if let input, inputCount > 0 {
                        remainder = Data(bytes: input, count: inputCount)
                    }
                    inputCount = 0
                case EINVAL, EILSEQ:
                    guard recoveringInvalidInput, input != nil, inputCount > 0 else {
                        throw RemoteCharsetConversionError(charset: charset, direction: errorDirection)
                    }
                    rejectedInput = true
                    self.reset()
                    inputCount -= 1
                    // iconv updates `input`; advance past the rejected source byte.
                    input = input?.advanced(by: 1)
                default:
                    throw RemoteCharsetConversionError(charset: charset, direction: errorDirection)
                }
            }
        }

        if final, !remainder.isEmpty {
            if recoveringInvalidInput {
                rejectedInput = true
                remainder.removeAll()
            } else {
                throw RemoteCharsetConversionError(charset: charset, direction: errorDirection)
            }
        }
        return Conversion(output: output, remainder: remainder, rejectedInput: rejectedInput)
    }

    private func reset() {
        _ = iconv(descriptor, nil, nil, nil, nil)
    }
}

/// Rewrites Shell Integration OSC 7 paths from the remote charset into a
/// percent-encoded UTF-8 payload before Ghostty parses them.
nonisolated struct RemoteOSC7CharsetFilter: Sendable {
    private static let maximumPayloadBytes = 64 * 1024
    struct Output: Sendable {
        var data = Data()
        var rejectedInput = false
    }

    private static let prefix = Data("\u{1B}]7;file://localhost".utf8)
    private let charset: RemoteCharset
    private var buffer = Data()

    init(charset: RemoteCharset) { self.charset = charset }

    mutating func receive(_ data: Data) -> Output {
        buffer.append(data)
        var output = Output()
        while let range = buffer.range(of: Self.prefix) {
            if range.lowerBound > buffer.startIndex {
                output.data.append(buffer[..<range.lowerBound])
            }
            guard let end = buffer[range.upperBound...].firstIndex(of: 0x07) else {
                if buffer.distance(from: range.upperBound, to: buffer.endIndex) > Self.maximumPayloadBytes {
                    buffer.removeAll(keepingCapacity: false)
                    output.rejectedInput = true
                } else {
                    buffer = Data(buffer[range.lowerBound...])
                }
                return output
            }
            let payload = Data(buffer[range.upperBound..<end])
            if let rewritten = rewrite(payload) {
                output.data.append(Self.prefix)
                output.data.append(rewritten)
                output.data.append(0x07)
            } else {
                output.rejectedInput = true
            }
            buffer = Data(buffer[buffer.index(after: end)...])
        }

        let retained = longestPrefixSuffix()
        let visibleEnd = buffer.index(buffer.endIndex, offsetBy: -retained)
        output.data.append(buffer[..<visibleEnd])
        buffer = Data(buffer[visibleEnd...])
        return output
    }

    mutating func finish() -> Data {
        defer { buffer.removeAll(keepingCapacity: false) }
        return buffer
    }

    private func rewrite(_ payload: Data) -> Data? {
        let bytes = Array(payload)
        var decoded = Data()
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x25, index + 2 < bytes.count,
                let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2])
            {
                decoded.append(high << 4 | low)
                index += 3
            } else {
                decoded.append(bytes[index])
                index += 1
            }
        }
        guard let path = try? RemoteCharsetStreamConverter.decode(decoded, charset: charset) else { return nil }
        var encoded = Data()
        for byte in path.utf8 {
            switch byte {
            case 0x2D, 0x2E, 0x2F, 0x30...0x39, 0x41...0x5A, 0x5F, 0x61...0x7A, 0x7E:
                encoded.append(byte)
            default:
                encoded.append(0x25)
                let digits = Array("0123456789ABCDEF".utf8)
                encoded.append(digits[Int(byte >> 4)])
                encoded.append(digits[Int(byte & 0x0F)])
            }
        }
        return encoded
    }

    private func longestPrefixSuffix() -> Int {
        guard !buffer.isEmpty else { return 0 }
        let maximum = min(buffer.count, Self.prefix.count - 1)
        guard maximum > 0 else { return 0 }
        for count in stride(from: maximum, through: 1, by: -1) {
            if buffer.suffix(count).elementsEqual(Self.prefix.prefix(count)) { return count }
        }
        return 0
    }

    private func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}
