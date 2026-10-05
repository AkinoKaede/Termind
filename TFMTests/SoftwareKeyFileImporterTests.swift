import Foundation
import TermindApplication
import TermindRemoteInfrastructure
import Testing

@Suite
struct SoftwareKeyFileImporterTests {
    @Test
    func privateKeyInfersItsCompleteFilename() throws {
        let url = try temporaryFile(
            named: "deploy.pem",
            contents: "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try SoftwareKeyFileImporter.read(urls: [url], infersName: true)

        #expect(result.privateKey?.contains("PRIVATE KEY") == true)
        #expect(result.inferredName == "deploy.pem")
    }

    @Test
    func manualNameIsNotReplaced() throws {
        let url = try temporaryFile(
            named: "deploy.pem",
            contents: "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try SoftwareKeyFileImporter.read(urls: [url], infersName: false)

        #expect(result.inferredName == nil)
        #expect(!SoftwareKeyFileImporter.shouldInferName(from: "Production"))
        #expect(SoftwareKeyFileImporter.shouldInferName(from: "  \n"))
    }

    @Test
    func certificateDoesNotInferAName() throws {
        let url = try temporaryFile(
            named: "deploy-cert.pub",
            contents: "ssh-ed25519-cert-v01@openssh.com AAAA"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try SoftwareKeyFileImporter.read(urls: [url], infersName: true)

        #expect(result.privateKey == nil)
        #expect(result.certificate == "ssh-ed25519-cert-v01@openssh.com AAAA")
        #expect(result.inferredName == nil)
    }

    @Test
    func finalPrivateKeyDeterminesContentAndInferredName() throws {
        let first = try temporaryFile(
            named: "first.pem",
            contents: "-----BEGIN OPENSSH PRIVATE KEY-----\nfirst"
        )
        let second = try temporaryFile(
            named: "second.key",
            contents: "-----BEGIN OPENSSH PRIVATE KEY-----\nsecond"
        )
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }

        let result = try SoftwareKeyFileImporter.read(
            urls: [first, second], infersName: true
        )

        #expect(result.privateKey?.contains("second") == true)
        #expect(result.inferredName == "second.key")
    }

    @Test
    func rejectsUnrecognizedText() throws {
        let url = try temporaryFile(named: "notes.txt", contents: "not a key")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(throws: CocoaError.self) {
            _ = try SoftwareKeyFileImporter.read(urls: [url], infersName: true)
        }
    }

    private func temporaryFile(named name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
