import Foundation
import TermindDomain

import struct TermindDomain.Host

nonisolated enum SSHUserCertificateError: LocalizedError, Equatable {
    case invalidFormat
    case unsupportedAlgorithm(String)
    case hostCertificate
    case keyMismatch

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            String(localized: "The certificate is not a valid OpenSSH user certificate.")
        case .unsupportedAlgorithm(let algorithm):
            String(localized: "Unsupported SSH certificate algorithm: \(algorithm)")
        case .hostCertificate:
            String(localized: "Host certificates cannot be used for user authentication.")
        case .keyMismatch:
            String(localized: "The certificate does not belong to this private key.")
        }
    }
}

nonisolated struct SSHUserCertificate: Hashable, Sendable {
    var authorizedKey: String
    var algorithm: SSHKeyAlgorithm
    var publicKeyBlob: Data
    var serial: UInt64
    var keyID: String
    var validAfter: Date
    var validBefore: Date?

    var validityWarning: String? {
        let now = Date()
        if now < validAfter {
            return String(localized: "This certificate is not valid yet.")
        }
        if let validBefore, now >= validBefore {
            return String(localized: "This certificate has expired.")
        }
        return nil
    }

    static func parse(_ text: String, matching publicKey: String? = nil) throws -> Self {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = normalized.split(whereSeparator: \Character.isWhitespace)
        guard fields.count >= 2,
            let blob = Data(base64Encoded: String(fields[1]))
        else { throw SSHUserCertificateError.invalidFormat }

        var reader = SSHWireReader(data: blob)
        guard let certificateMethodData = reader.readField(),
            let certificateMethod = String(data: certificateMethodData, encoding: .utf8),
            certificateMethod == String(fields[0]),
            certificateMethod.hasSuffix("-cert-v01@openssh.com"),
            reader.readField() != nil
        else { throw SSHUserCertificateError.invalidFormat }

        let algorithm: SSHKeyAlgorithm
        let plainMethod: String
        let keyFields: [Data]
        switch certificateMethod {
        case "ssh-ed25519-cert-v01@openssh.com":
            algorithm = .ed25519
            plainMethod = SSHKeyAlgorithm.ed25519.rawValue
            keyFields = try reader.readFields(count: 1)
        case "ecdsa-sha2-nistp256-cert-v01@openssh.com":
            algorithm = .ecdsa256
            plainMethod = SSHKeyAlgorithm.ecdsa256.rawValue
            keyFields = try reader.readFields(count: 2)
        case "ecdsa-sha2-nistp384-cert-v01@openssh.com":
            algorithm = .ecdsa384
            plainMethod = SSHKeyAlgorithm.ecdsa384.rawValue
            keyFields = try reader.readFields(count: 2)
        case "ecdsa-sha2-nistp521-cert-v01@openssh.com":
            algorithm = .ecdsa521
            plainMethod = SSHKeyAlgorithm.ecdsa521.rawValue
            keyFields = try reader.readFields(count: 2)
        case "ssh-rsa-cert-v01@openssh.com",
            "rsa-sha2-256-cert-v01@openssh.com",
            "rsa-sha2-512-cert-v01@openssh.com":
            algorithm = .rsa
            plainMethod = SSHKeyAlgorithm.rsa.rawValue
            keyFields = try reader.readFields(count: 2)
        default:
            throw SSHUserCertificateError.unsupportedAlgorithm(certificateMethod)
        }

        guard let serial = reader.readUInt64(), let type = reader.readUInt32(),
            let keyIDData = reader.readField(),
            reader.readField() != nil,
            let validAfter = reader.readUInt64(), let validBefore = reader.readUInt64(),
            reader.readField() != nil, reader.readField() != nil,
            reader.readField() != nil, reader.readField() != nil,
            reader.readField() != nil, reader.isAtEnd
        else { throw SSHUserCertificateError.invalidFormat }
        guard type == 1 else {
            if type == 2 { throw SSHUserCertificateError.hostCertificate }
            throw SSHUserCertificateError.invalidFormat
        }

        let publicBlob =
            SSHWireWriter.field(Data(plainMethod.utf8))
            + keyFields.reduce(into: Data()) { $0.append(SSHWireWriter.field($1)) }
        if let publicKey {
            let publicFields = publicKey.split(whereSeparator: \Character.isWhitespace)
            guard publicFields.count >= 2,
                let expected = Data(base64Encoded: String(publicFields[1])),
                expected == publicBlob
            else { throw SSHUserCertificateError.keyMismatch }
        }

        return Self(
            authorizedKey: normalized, algorithm: algorithm, publicKeyBlob: publicBlob,
            serial: serial, keyID: String(data: keyIDData, encoding: .utf8) ?? "",
            validAfter: Date(timeIntervalSince1970: TimeInterval(validAfter)),
            validBefore: validBefore == UInt64.max
                ? nil : Date(timeIntervalSince1970: TimeInterval(validBefore))
        )
    }
}

private nonisolated struct SSHWireReader {
    let data: Data
    var offset = 0
    var isAtEnd: Bool { offset == data.count }

    mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let value = data[offset..<(offset + 4)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        offset += 4
        return value
    }

    mutating func readUInt64() -> UInt64? {
        guard offset + 8 <= data.count else { return nil }
        let value = data[offset..<(offset + 8)].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
        offset += 8
        return value
    }

    mutating func readField() -> Data? {
        guard let length = readUInt32(), offset + Int(length) <= data.count
        else { return nil }
        defer { offset += Int(length) }
        return data[offset..<(offset + Int(length))]
    }

    mutating func readFields(count: Int) throws -> [Data] {
        var result: [Data] = []
        for _ in 0..<count {
            guard let field = readField() else { throw SSHUserCertificateError.invalidFormat }
            result.append(field)
        }
        return result
    }
}

private nonisolated enum SSHWireWriter {
    static func field(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + data
    }
}
