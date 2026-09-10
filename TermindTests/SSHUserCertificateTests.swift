import Foundation
import Testing

@testable import Termind

struct SSHUserCertificateTests {
    @Test
    func parsesMatchingUserCertificateAndReportsValidity() throws {
        let material = try SSHKeyMaterial.generate(
            .ed25519, comment: "certificate-test", passphrase: nil
        )
        let certificate = try makeEd25519Certificate(
            publicKey: material.publicKey, type: 1,
            validAfter: UInt64(Date().timeIntervalSince1970) - 60,
            validBefore: UInt64(Date().timeIntervalSince1970) + 3_600
        )

        let parsed = try SSHUserCertificate.parse(
            certificate, matching: material.publicKey
        )

        #expect(parsed.algorithm == .ed25519)
        #expect(parsed.serial == 42)
        #expect(parsed.keyID == "termind-test")
        #expect(parsed.validityWarning == nil)
    }

    @Test
    func rejectsHostCertificateAndMismatchedKey() throws {
        let first = try SSHKeyMaterial.generate(.ed25519, comment: "first", passphrase: nil)
        let second = try SSHKeyMaterial.generate(.ed25519, comment: "second", passphrase: nil)
        let hostCertificate = try makeEd25519Certificate(
            publicKey: first.publicKey, type: 2,
            validAfter: 0, validBefore: UInt64.max
        )
        #expect(throws: SSHUserCertificateError.hostCertificate) {
            try SSHUserCertificate.parse(hostCertificate, matching: first.publicKey)
        }

        let userCertificate = try makeEd25519Certificate(
            publicKey: first.publicKey, type: 1,
            validAfter: 0, validBefore: UInt64.max
        )
        #expect(throws: SSHUserCertificateError.keyMismatch) {
            try SSHUserCertificate.parse(userCertificate, matching: second.publicKey)
        }
    }

    @Test
    func acceptsExpiredCertificateWithWarning() throws {
        let material = try SSHKeyMaterial.generate(
            .ed25519, comment: "expired", passphrase: nil
        )
        let now = UInt64(Date().timeIntervalSince1970)
        let certificate = try makeEd25519Certificate(
            publicKey: material.publicKey, type: 1,
            validAfter: now - 3_600, validBefore: now - 60
        )
        let parsed = try SSHUserCertificate.parse(
            certificate, matching: material.publicKey
        )
        #expect(parsed.validityWarning != nil)
    }

    @Test
    @MainActor
    func folderImportAssociatesExplicitCertificatesWithTheirHost() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SSHCertificateImport-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: nil)
        let certificate = try makeEd25519Certificate(
            publicKey: material.publicKey, type: 1, validAfter: 0, validBefore: UInt64.max)
        try material.privateKey.write(to: root.appendingPathComponent("deploy"), atomically: true, encoding: .utf8)
        try certificate.write(to: root.appendingPathComponent("user-cert.pub"), atomically: true, encoding: .utf8)
        try
            "Host certified\nIdentityFile ~/.ssh/deploy\nCertificateFile ~/.ssh/user-cert.pub\nHost plain\nIdentityFile ~/.ssh/deploy"
            .write(
                to: root.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let model = SSHImportModel(library: HostLibraryModel(), reader: SSHImportReader())
        await model.scan(root, knownHostsOnly: false)
        let certified = try #require(model.items.first { $0.name == "certified" })
        let plain = try #require(model.items.first { $0.name == "plain" })
        #expect(model.chosenKey(for: certified)?.certificate == certificate)
        #expect(model.chosenKey(for: plain)?.certificate == "")
        #expect(model.canImport)
    }

    private func makeEd25519Certificate(
        publicKey: String, type: UInt32, validAfter: UInt64, validBefore: UInt64
    ) throws -> String {
        let parts = publicKey.split(whereSeparator: \Character.isWhitespace)
        let publicBlob = try #require(Data(base64Encoded: String(parts[1])))
        var reader = TestSSHReader(data: publicBlob)
        let method = reader.field()
        let keyField = reader.field()
        _ = try #require(method)
        let key = try #require(keyField)

        var blob = Data()
        blob.append(field(Data("ssh-ed25519-cert-v01@openssh.com".utf8)))
        blob.append(field(Data("nonce".utf8)))
        blob.append(field(key))
        blob.append(uint64(42))
        blob.append(uint32(type))
        blob.append(field(Data("termind-test".utf8)))
        blob.append(field(Data()))  // principals
        blob.append(uint64(validAfter))
        blob.append(uint64(validBefore))
        blob.append(field(Data()))  // critical options
        blob.append(field(Data()))  // extensions
        blob.append(field(Data()))  // reserved
        blob.append(field(Data("ca".utf8)))
        blob.append(field(Data("signature".utf8)))
        return "ssh-ed25519-cert-v01@openssh.com \(blob.base64EncodedString())"
    }

    private func field(_ value: Data) -> Data { uint32(UInt32(value.count)) + value }

    private func uint32(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    private func uint64(_ value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
}

private struct TestSSHReader {
    let data: Data
    var offset = 0

    mutating func field() -> Data? {
        guard offset + 4 <= data.count else { return nil }
        let length = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        offset += 4
        guard offset + length <= data.count else { return nil }
        defer { offset += length }
        return data[offset..<(offset + length)]
    }
}
