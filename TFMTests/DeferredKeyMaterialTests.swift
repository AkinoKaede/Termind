import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

struct DeferredKeyMaterialTests {
    @Test func nestedSSHFieldsAcceptDataSlicesWithNonzeroIndices() throws {
        let container = Data([99, 99, 0, 0, 0, 7, 0, 0, 0, 3, 1, 2, 3])
        let slice = container.dropFirst(2)
        #expect(slice.startIndex != 0)
        var offset = 0
        let nested = try #require(SSHKeyMaterial.readSSHField(slice, offset: &offset))
        #expect(offset == slice.count)
        var nestedOffset = 0
        #expect(SSHKeyMaterial.readSSHField(nested, offset: &nestedOffset) == Data([1, 2, 3]))
        #expect(nestedOffset == nested.count)
    }

    @Test func invalidSSHFieldBoundsFailWithoutTrappingOrAdvancing() {
        for bytes in [Data([0, 0, 0]), Data([255, 255, 255, 255]), Data([0, 0, 0, 2, 1])] {
            for initialOffset in [-1, 0, Int.max] {
                var offset = initialOffset
                #expect(SSHKeyMaterial.readSSHField(bytes, offset: &offset) == nil)
                #expect(offset == initialOffset)
            }
        }
    }

    @Test(arguments: [SSHKeyMaterial.Generation.ed25519, .rsa(bits: 2048), .ecdsa(bits: 256)])
    func importRecognizesEncryptionWithoutUnlockingOrDeriving(_ generation: SSHKeyMaterial.Generation) throws {
        let encrypted = try SSHKeyMaterial.generate(generation, comment: "test", passphrase: "secret")
        let metadata = try SSHKeyMaterial.privateKeyMetadata(encrypted.privateKey)
        #expect(metadata.isEncrypted && metadata.algorithm == .unknown)
        let imported = try SSHKeyMaterial.imported(privateKey: encrypted.privateKey, publicKey: "")
        #expect(imported.publicKey.isEmpty && imported.fingerprint.isEmpty && imported.algorithm == .unknown)
        let supplied = try SSHKeyMaterial.imported(privateKey: encrypted.privateKey, publicKey: encrypted.publicKey)
        #expect(supplied.fingerprint == encrypted.fingerprint && supplied.algorithm == encrypted.algorithm)
        let plaintext = try SSHKeyMaterial.generate(generation, comment: "", passphrase: nil)
        #expect(try !SSHKeyMaterial.privateKeyMetadata(plaintext.privateKey).isEncrypted)
        #expect(try SSHKeyMaterial.imported(privateKey: plaintext.privateKey, publicKey: "").publicKey.isEmpty)
    }

    @Test(arguments: [
        "", "not a key", "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----",
    ])
    func invalidPrivateEnvelopesCannotBeSaved(_ input: String) {
        #expect(throws: (any Error).self) { try SSHKeyMaterial.imported(privateKey: input, publicKey: "") }
    }

    @Test func analysisRetainsEncryptionMetadataWhenPublicMaterialIsInvalid() throws {
        let encrypted = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: "test")
        let analysis = try SSHKeyMaterial.analyzeImport(privateKey: encrypted.privateKey, publicKey: "invalid")
        #expect(analysis.metadata.isEncrypted)
        #expect(throws: (any Error).self) { try analysis.material.get() }
        #expect(throws: (any Error).self) {
            try SSHKeyMaterial.imported(privateKey: encrypted.privateKey, publicKey: "invalid")
        }
        let corrected = try SSHKeyMaterial.analyzeImport(
            privateKey: encrypted.privateKey, publicKey: encrypted.publicKey)
        #expect(try corrected.material.get().fingerprint == encrypted.fingerprint)
    }

    @Test func analysisRejectsMismatchedPublicAlgorithm() throws {
        let privateMaterial = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: nil)
        let publicMaterial = try SSHKeyMaterial.generate(.ecdsa(bits: 256), comment: "", passphrase: nil)
        let analysis = try SSHKeyMaterial.analyzeImport(
            privateKey: privateMaterial.privateKey, publicKey: publicMaterial.publicKey)
        #expect(!analysis.metadata.isEncrypted)
        #expect(throws: (any Error).self) { try analysis.material.get() }
    }

    @Test func suppliedPublicKeyMustHaveAValidWireBlob() throws {
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: nil)
        for value in [
            "ssh-ed25519 AAAA", material.publicKey + "\n" + material.publicKey,
            material.publicKey.replacingOccurrences(of: "ssh-ed25519", with: "ssh-rsa"),
        ] {
            #expect(throws: (any Error).self) { try SSHKeyMaterial.publicMaterial(value) }
        }
    }

    @Test func opensshAndTraditionalPEMEncryptionIsDetectedWithoutAPassphrase() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (format, type) in [("", "ed25519"), ("PEM", "rsa"), ("PEM", "ecdsa")] {
            let path = directory.appending(path: UUID().uuidString).path
            var args = ["-q", "-t", type, "-N", "fixture-passphrase", "-f", path]
            if !format.isEmpty { args += ["-m", format] }
            try run("/usr/bin/ssh-keygen", args)
            let text = try String(contentsOfFile: path, encoding: .utf8)
            #expect(try SSHKeyMaterial.privateKeyMetadata(text).isEncrypted)
            #expect(try SSHKeyMaterial.imported(privateKey: text, publicKey: "").publicKey.isEmpty)
        }
    }

    @Test(arguments: ["ed25519", "rsa", "ecdsa"])
    func editingUnencryptedOpenSSHKeysReadsNestedMetadataWithoutDeriving(_ type: String) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "key").path
        try run("/usr/bin/ssh-keygen", ["-q", "-t", type, "-N", "", "-f", path])
        let privateKey = try String(contentsOfFile: path, encoding: .utf8)
        let publicKey = try String(contentsOfFile: path + ".pub", encoding: .utf8)
        #expect(try !SSHKeyMaterial.privateKeyMetadata(privateKey).isEncrypted)
        let material = try SSHKeyMaterial.imported(privateKey: privateKey, publicKey: publicKey)
        #expect(material.algorithm != .unknown && !material.fingerprint.isEmpty)
        #expect(try SSHKeyMaterial.imported(privateKey: privateKey, publicKey: "").publicKey.isEmpty)
    }

    @Test func defaultExportScriptQuotesArgumentsAndDoesNotDuplicateTheKey() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "keys '$HOME; $(touch injected)")
        let name = "authorized_keys';touch injected;#"
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "$(touch injected)", passphrase: nil)
        let options = KeyExportOptions(
            directory: directory.path, filename: name,
            script: KeyExportOptions.defaultScript(keyName: "Work\n$(touch injected)"))
        let command = try SSHKeyExportSession.command(publicKey: material.publicKey, options: options)
        try run("/bin/sh", ["-c", command], directory: root)
        try run("/bin/sh", ["-c", command], directory: root)
        let file = directory.appending(path: name)
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.components(separatedBy: material.publicKey).count == 2)
        #expect(contents.hasPrefix("# Work $(touch injected) Key by Termind\n"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "injected").path))
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func customScriptReceivesThreeLiteralArguments() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "comment", passphrase: nil)
        let options = KeyExportOptions(
            directory: root.path, filename: "custom",
            script: "printf '%s\\n%s\\n' \"$2\" \"$3\" > \"$1/$2\"")
        try run("/bin/sh", ["-c", SSHKeyExportSession.command(publicKey: material.publicKey, options: options)])
        #expect(
            try String(contentsOf: root.appending(path: "custom"), encoding: .utf8) == "custom\n\(material.publicKey)\n"
        )
    }

    @Test func defaultScriptPreservesAnExistingKeyWithoutATrailingNewline() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = try SSHKeyMaterial.generate(.ed25519, comment: "existing", passphrase: nil)
        let next = try SSHKeyMaterial.generate(.ed25519, comment: "next", passphrase: nil)
        let file = root.appending(path: "authorized_keys")
        try existing.publicKey.write(to: file, atomically: true, encoding: .utf8)
        let options = KeyExportOptions(directory: root.path, script: KeyExportOptions.defaultScript(keyName: "Next"))
        try run("/bin/sh", ["-c", SSHKeyExportSession.command(publicKey: next.publicKey, options: options)])
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == [existing.publicKey, "# Next Key by Termind", next.publicKey])
    }

    private func run(_ executable: String, _ arguments: [String], directory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(output)")
        guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
    }
}
