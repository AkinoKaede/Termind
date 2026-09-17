import CryptoKit
import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@testable import TermindIOS

@MainActor
struct MobileSFTPEditedCopyImporterTests {
    @Test func importedCopyBecomesAPendingEditWithoutUploadingOrChangingRemoteIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let baseline = try #require(fixture.edits.model.file(fixture.id)?.baseline)
        await fixture.workspace.importEditedCopy(fixture.source, for: fixture.id)
        #expect(fixture.workspace.operationError == nil)
        #expect(try Data(contentsOf: fixture.original) == Data([3, 2, 1]))
        #expect(try Data(contentsOf: fixture.source) == Data([3, 2, 1]))
        let entry = try #require(fixture.edits.model.file(fixture.id))
        #expect(entry.localURL == fixture.original)
        #expect(entry.remotePath == "/srv/document.txt")
        #expect(entry.baseline == baseline)
        #expect(entry.isModified)
        #expect(fixture.transfers.sftpTransfers.isEmpty)
    }

    @Test func differentFormatsAndDiscardedRecordsNeverReplaceTheManagedFile() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let otherFormat = fixture.directory.appending(path: "edited.pdf")
        try Data([4]).write(to: otherFormat)
        await fixture.workspace.importEditedCopy(otherFormat, for: fixture.id)
        #expect(fixture.workspace.operationError != nil)
        #expect(try Data(contentsOf: fixture.original) == Data([1, 2, 3]))
        await fixture.edits.discard(fixture.id)
        await fixture.workspace.importEditedCopy(fixture.source, for: fixture.id)
        #expect(try Data(contentsOf: fixture.original) == Data([1, 2, 3]))
    }

    @Test func invalidatedOrUploadingRecordsKeepTheirCurrentContents() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.edits.model.update(fixture.id) { $0.transferID = UUID() }
        await fixture.workspace.importEditedCopy(fixture.source, for: fixture.id)
        #expect(try Data(contentsOf: fixture.original) == Data([1, 2, 3]))
        fixture.edits.model.update(fixture.id) {
            $0.transferID = nil
            $0.isInvalidated = true
        }
        await fixture.workspace.importEditedCopy(fixture.source, for: fixture.id)
        #expect(try Data(contentsOf: fixture.original) == Data([1, 2, 3]))
    }

    private struct Fixture {
        let directory: URL
        let original: URL
        let source: URL
        let edits: SFTPEditService
        let transfers: SFTPTransferCoordinator
        let workspace: MobileWorkspace
        let id: UUID

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            original = directory.appending(path: "document.txt")
            source = directory.appending(path: "edited.txt")
            try Data([1, 2, 3]).write(to: original)
            try Data([3, 2, 1]).write(to: source)
            let host = TermindDomain.Host(name: "Test", host: "example.invalid")
            let library = HostLibraryModel(hosts: [host])
            transfers = SFTPTransferCoordinator(store: library, clientFactory: { SFTPClient() })
            edits = SFTPEditService(transfers: transfers)
            edits.setMonitoring(false)
            let file = RemoteFile(
                path: "/srv/document.txt", name: "document.txt", kind: .file, size: 3,
                permissions: 0o644, ownerUID: 0, ownerGID: 0)
            let digest = SHA256.hash(data: Data([1, 2, 3])).map { String(format: "%02x", $0) }.joined()
            id = edits.model.register(hostID: host.id, file: file, localURL: original, digest: digest)
            workspace = MobileWorkspace(
                descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .sftp),
                hosts: library, transfers: transfers, sftpEdits: edits)
        }

        func clean() { try? FileManager.default.removeItem(at: directory) }
    }
}
