import Foundation
import TermindApplication

/// Incremental, bounded SSH agent framing. Unknown management messages fail closed.
nonisolated struct SSHAgentProtocol {
    static let maximumPacket = 256 * 1024
    private(set) var bytes = Data()

    mutating func append(_ data: Data) throws {
        guard bytes.count + data.count <= Self.maximumPacket + 4 else { throw Failure.invalid }
        bytes.append(data)
        if bytes.count >= 4 {
            var reader = Reader(bytes)
            let length = try reader.uint32()
            guard length > 0, length <= Self.maximumPacket else { throw Failure.invalid }
        }
    }

    mutating func next() throws -> Data? {
        guard bytes.count >= 4 else { return nil }
        var reader = Reader(bytes)
        let length = Int(try reader.uint32())
        guard length > 0, length <= Self.maximumPacket else { throw Failure.invalid }
        guard bytes.count >= length + 4 else { return nil }
        let packet = Data(bytes.dropFirst(4).prefix(length))
        bytes = Data(bytes.dropFirst(length + 4))
        return packet
    }

    static func response(to packet: Data, provider: any SSHAgentForwarding) async -> Data {
        do {
            try Task.checkCancellation()
            guard let kind = packet.first else { throw Failure.invalid }
            var reader = Reader(Data(packet.dropFirst()))
            switch kind {
            case 11:  // SSH2_AGENTC_REQUEST_IDENTITIES
                guard reader.isEmpty else { throw Failure.invalid }
                let identities = try await provider.identities()
                try Task.checkCancellation()
                guard identities.count <= 1024 else { throw Failure.invalid }
                var reply = Data([12]) + uint32(UInt32(identities.count))
                for identity in identities {
                    reply += field(identity.blob) + field(Data(identity.comment.utf8))
                    guard reply.count <= maximumPacket else { throw Failure.invalid }
                }
                return frame(reply)
            case 13:  // SSH2_AGENTC_SIGN_REQUEST
                let key = try reader.field()
                let data = try reader.field()
                let flags = try reader.uint32()
                guard reader.isEmpty else { throw Failure.invalid }
                let signature = try await provider.sign(key: key, data: data, flags: flags)
                try Task.checkCancellation()
                guard signature.count < maximumPacket - 5 else { throw Failure.invalid }
                return frame(Data([14]) + field(signature))
            default: return frame(Data([5]))
            }
        } catch { return frame(Data([5])) }
    }

    enum Failure: Error { case invalid, unavailable }
    static func uint32(_ value: UInt32) -> Data { SSHWireEncoding.uint32(value) }
    static func field(_ data: Data) -> Data { SSHWireEncoding.field(data) }
    static func frame(_ data: Data) -> Data { field(data) }

    struct Reader {
        let data: Data
        var offset = 0
        init(_ data: Data) { self.data = Data(data) }
        var isEmpty: Bool { offset == data.count }
        mutating func uint32() throws -> UInt32 {
            guard data.count - offset >= 4 else { throw Failure.invalid }
            defer { offset += 4 }
            return data[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        mutating func field() throws -> Data {
            let count = Int(try uint32())
            guard count <= data.count - offset else { throw Failure.invalid }
            defer { offset += count }
            return data.subdata(in: offset..<offset + count)
        }
    }
}
