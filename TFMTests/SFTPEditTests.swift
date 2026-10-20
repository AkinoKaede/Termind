// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import Termind
@testable import TermindRemoteInfrastructure

@Suite @MainActor
struct SFTPEditTests {
    @Test func browserOpenReusesTheTrackedCopyAndRetainsEditUploadSupport() async throws {
        let fixture = Fixture()
        let configuration = SSHConnectionConfiguration(
            hostID: fixture.hostID, host: "example.invalid", port: 22, username: "test", credentials: [],
            expectedHostKeys: [])
        let channel = SFTPChannelModel(hostID: fixture.hostID, client: fixture.client, configuration: configuration)
        let file = await fixture.client.file
        var opened: URL?
        channel.open(file, coordinator: fixture.transfers, edits: fixture.service) { opened = $0 }
        try await wait { opened != nil }
        let url = try #require(opened)
        defer { fixture.clean(url) }
        let id = try #require(fixture.service.model.files.first?.id)
        try Data([7, 6, 5]).write(to: url, options: .atomic)
        opened = nil
        channel.open(file, coordinator: fixture.transfers, edits: fixture.service) { opened = $0 }
        try await wait { opened != nil }
        #expect(opened == url)
        #expect(await fixture.client.downloads == 1)
        await fixture.service.recheck()
        #expect(fixture.service.model.file(id)?.isModified == true)
        #expect(await channel.uploadEdit(id, using: fixture.service, replacing: false) == false)
        try await wait { fixture.service.model.file(id)?.transferID == nil }
        #expect(await fixture.client.data == Data([7, 6, 5]))
    }

    @Test(arguments: ["config", "file.txt", "image.png", "archive.zip", "data.sqlite", "document.pdf"])
    func arbitraryBinaryContentsAndAtomicSavesAreDetected(_ name: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        let original = Data([0, 255, 13, 10, 127])
        try original.write(to: url)
        let files = SFTPEditLocalFiles()
        let before = try await files.digest(url)
        let edited = Data([255, 0, 13, 10, 127])
        try edited.write(to: url, options: .atomic)
        let after = try await files.digest(url, force: false)
        #expect(before != after)
        let snapshot = try await files.snapshot(url)
        try original.write(to: url, options: .atomic)
        #expect(try Data(contentsOf: snapshot.url) == edited)
        #expect(try await files.digest(url) == before)
        await files.removeSnapshot(snapshot)
        #expect(!FileManager.default.fileExists(atPath: snapshot.url.path))
    }

    @Test func duplicateOpenReusesCopyAndSuccessfulUploadHidesTheCard() async throws {
        let fixture = Fixture()
        let url = try await fixture.open()
        defer { fixture.clean(url) }
        let original = await fixture.client.file
        #expect(try await fixture.open() == url)
        #expect(await fixture.client.downloads == 1)
        #expect(fixture.service.model.modifiedFiles(for: fixture.hostID).isEmpty)
        try Data([4, 3, 2, 1]).write(to: url, options: .atomic)
        await fixture.service.recheck()
        let id = try #require(fixture.service.model.files.first?.id)
        #expect(fixture.service.model.modifiedFiles(for: fixture.hostID).count == 1)
        #expect(await fixture.upload(id) == false)
        try await wait { fixture.service.model.file(id)?.transferID == nil }
        #expect(await fixture.client.data == Data([4, 3, 2, 1]))
        #expect(await fixture.client.lastPolicy?.permissions == original.permissionMode)
        #expect(fixture.service.model.modifiedFiles(for: fixture.hostID).isEmpty)
    }

    @Test func downloadReceiptAllowsTheBrowserConnectionToCloseBeforeEditingStarts() async throws {
        let fixture = Fixture()
        await fixture.client.retireBrowserOnDownload()
        let url = try await fixture.open()
        defer { fixture.clean(url) }
        #expect(fixture.service.model.files.count == 1)
        #expect(try Data(contentsOf: url) == Data([1, 2, 3, 4]))
    }

    @Test func conflictRequiresConfirmationAndConfirmationExpiresOnAnotherRemoteChange() async throws {
        let fixture = Fixture()
        let url = try await fixture.open()
        defer { fixture.clean(url) }
        try Data([9]).write(to: url)
        let id = try #require(fixture.service.model.files.first?.id)
        await fixture.client.remoteChange()
        #expect(await fixture.upload(id))
        #expect(await fixture.client.uploads == 0)
        await fixture.client.remoteChange()
        #expect(await fixture.upload(id, replacing: true))
        #expect(await fixture.client.uploads == 0)
        #expect(await fixture.upload(id, replacing: true) == false)
        try await wait { fixture.service.model.file(id)?.transferID == nil }
        #expect(await fixture.client.data == Data([9]))
    }

    @Test func savesDuringUploadRemainPendingAndUseAnImmutableSnapshot() async throws {
        let fixture = Fixture()
        let url = try await fixture.open()
        defer { fixture.clean(url) }
        let id = try #require(fixture.service.model.files.first?.id)
        await fixture.client.hold()
        try Data([2]).write(to: url)
        _ = await fixture.upload(id)
        try await wait { await fixture.client.uploads == 1 }
        try Data([3]).write(to: url, options: .atomic)
        await fixture.service.recheck()
        await fixture.client.release()
        try await wait { fixture.service.model.file(id)?.transferID == nil }
        #expect(await fixture.client.data == Data([2]))
        #expect(fixture.service.model.file(id)?.isModified == true)
    }

    @Test func connectionLossPausesUntilExplicitResumeAndRetainsTheSnapshot() async throws {
        let fixture = Fixture()
        let url = try await fixture.open()
        defer { fixture.clean(url) }
        try Data([6]).write(to: url)
        let id = try #require(fixture.service.model.files.first?.id)
        await fixture.client.loseNextUpload()
        _ = await fixture.upload(id)
        let transfer = try #require(fixture.service.model.file(id)?.transferID)
        try await wait { fixture.transfers.sftpTransfers.first { $0.id == transfer }?.state == .paused }
        let snapshot = try #require(fixture.transfers.sftpTransfers.first { $0.id == transfer }?.localPath)
        #expect(FileManager.default.fileExists(atPath: snapshot))
        fixture.transfers.resume(transfer)
        try await wait { fixture.service.model.file(id)?.transferID == nil }
        #expect(await fixture.client.data == Data([6]))
        #expect(!FileManager.default.fileExists(atPath: snapshot))
    }

    @Test func hostInvalidationRetainsLocalChangesAndPreventsUpload() async throws {
        let fixture = Fixture()
        let url = try await fixture.open()
        defer { fixture.clean(url) }
        try Data([8]).write(to: url)
        await fixture.service.recheck()
        let id = try #require(fixture.service.model.files.first?.id)
        fixture.service.invalidate(hostID: fixture.hostID)
        #expect(await fixture.upload(id) == false)
        #expect(await fixture.client.uploads == 0)
        #expect(fixture.service.model.modifiedFiles(for: fixture.hostID).count == 1)
        #expect(try Data(contentsOf: url) == Data([8]))
    }

    @Test func fileObservationDetectsRepeatedAtomicSavesWithoutForegroundRefresh() async throws {
        let fixture = Fixture()
        let url = try await fixture.open()
        defer {
            fixture.service.setMonitoring(false)
            fixture.clean(url)
        }
        fixture.service.setMonitoring(true)
        let id = try #require(fixture.service.model.files.first?.id)
        let original = try Data(contentsOf: url)
        try Data([7, 7, 7, 7]).write(to: url, options: .atomic)
        try await wait { fixture.service.model.file(id)?.isModified == true }
        try original.write(to: url, options: .atomic)
        try await wait { fixture.service.model.file(id)?.isModified == false }
    }

    @Test func routeChangesAreRejectedEvenWhenTheHostIdentifierStaysTheSame() async throws {
        let fixture = Fixture()
        var currentHost = TermindDomain.Host(id: fixture.hostID, name: "Test", host: "first.invalid")
        let service = SFTPEditService(transfers: fixture.transfers, host: { _ in currentHost })
        service.setMonitoring(false)
        let url = try await service.open(
            fixture.client.file, hostID: fixture.hostID, connection: fixture.connection, client: fixture.client)
        defer { fixture.clean(url) }
        try Data([9]).write(to: url)
        currentHost.host = "second.invalid"
        await service.recheck()
        let id = try #require(service.model.files.first?.id)
        #expect(service.model.file(id)?.isInvalidated == true)
        #expect(await service.upload(id, connection: fixture.connection, client: fixture.client) == false)
        #expect(await fixture.client.uploads == 0)
    }

    @Test func reconnectingWithADifferentAccountCannotUploadAnOldCopy() async throws {
        let fixture = Fixture()
        var snapshot = SSHAdditionalConnectionSnapshot(
            configuration: SSHConnectionConfiguration(
                hostID: fixture.hostID, host: "test.invalid", port: 22,
                username: "first", credentials: [], expectedHostKeys: []))
        let url = try await fixture.service.open(
            fixture.client.file, hostID: fixture.hostID, connection: fixture.connection,
            client: fixture.client, snapshot: snapshot)
        defer { fixture.clean(url) }
        try Data([9]).write(to: url)
        let id = try #require(fixture.service.model.files.first?.id)
        snapshot.target.authentication.username = "second"
        #expect(
            await fixture.service.upload(
                id, connection: fixture.connection, client: fixture.client, snapshot: snapshot) == false)
        #expect(fixture.service.model.file(id)?.isInvalidated == true)
        #expect(await fixture.client.uploads == 0)
    }

    @Test func failedAndCancelledUploadsKeepChangesAndReleaseTheirSnapshots() async throws {
        let fixture = Fixture()
        let url = try await fixture.open()
        defer { fixture.clean(url) }
        try Data([5]).write(to: url)
        let id = try #require(fixture.service.model.files.first?.id)
        await fixture.client.failNextUpload()
        _ = await fixture.upload(id)
        try await wait { fixture.service.model.file(id)?.transferID == nil }
        #expect(fixture.service.model.file(id)?.isModified == true)
        #expect(fixture.service.model.file(id)?.error != nil)
        await fixture.client.hold()
        _ = await fixture.upload(id)
        let transferID = try #require(fixture.service.model.file(id)?.transferID)
        let transfer = try #require(fixture.transfers.sftpTransfers.first { $0.id == transferID })
        fixture.transfers.cancel(transferID)
        try await wait { fixture.service.model.file(id)?.transferID == nil }
        #expect(!FileManager.default.fileExists(atPath: transfer.localPath))
        #expect(fixture.service.model.file(id)?.isModified == true)
        await fixture.client.release()
        _ = await fixture.upload(id)
        try await wait { fixture.service.model.file(id)?.transferID == nil }
        #expect(fixture.service.model.file(id)?.isModified == false)
    }

    @Test func discardingStopsTrackingWithoutDeletingTheCopyOrChangingTheRemote() async throws {
        let fixture = Fixture()
        let url = try await fixture.open()
        defer { fixture.clean(url) }
        try Data([7]).write(to: url)
        await fixture.service.recheck()
        let id = try #require(fixture.service.model.files.first?.id)
        await fixture.service.discard(id)
        #expect(fixture.service.model.files.isEmpty)
        #expect(try Data(contentsOf: url) == Data([7]))
        #expect(await fixture.client.uploads == 0)
        let reopened = try await fixture.open()
        defer { fixture.clean(reopened) }
        #expect(reopened != url)
        #expect(try Data(contentsOf: reopened) == Data([1, 2, 3, 4]))
    }

    @Test func discardingAPausedUploadCleansItsSnapshotButCannotDiscardAnActiveUpload() async throws {
        let fixture = Fixture()
        let url = try await fixture.open()
        defer { fixture.clean(url) }
        try Data([8]).write(to: url)
        let id = try #require(fixture.service.model.files.first?.id)
        await fixture.client.hold()
        _ = await fixture.upload(id)
        let transferID = try #require(fixture.service.model.file(id)?.transferID)
        try await wait { await fixture.client.uploads == 1 }
        await fixture.service.discard(id)
        #expect(fixture.service.model.file(id) != nil)
        fixture.transfers.pause(transferID)
        try await wait { fixture.transfers.sftpTransfers.first { $0.id == transferID }?.state == .paused }
        let snapshot = try #require(fixture.transfers.sftpTransfers.first { $0.id == transferID }?.localPath)
        await fixture.service.discard(id)
        #expect(fixture.service.model.files.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: snapshot))
        #expect(try Data(contentsOf: url) == Data([8]))
        #expect(await fixture.client.data == Data([1, 2, 3, 4]))
    }

    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Edit transfer did not reach its expected state")
        throw SFTPError.notConnected
    }

    private final class Fixture {
        let hostID = UUID()
        let client = EditClient()
        let transfers: SFTPTransferCoordinator
        let service: SFTPEditService
        private lazy var context = SFTPTransferContext(
            snapshot: SSHAdditionalConnectionSnapshot(
                configuration: SSHConnectionConfiguration(
                    hostID: hostID, host: "fixture.invalid", port: 22,
                    username: "test", credentials: [], expectedHostKeys: [])),
            channel: client, primaryRole: .ptyConnectionFallback)
        var connection: SFTPTransferConnection { .context(context) }
        init() {
            let client = client
            transfers = SFTPTransferCoordinator(store: HostLibraryModel(), clientFactory: { client })
            service = SFTPEditService(transfers: transfers)
            service.setMonitoring(false)
        }
        func open() async throws -> URL {
            try await service.open(client.file, hostID: hostID, connection: connection, client: client)
        }
        func upload(_ id: UUID, replacing: Bool = false) async -> Bool {
            await service.upload(id, connection: connection, client: client, replacing: replacing)
        }
        func clean(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
}

private actor EditClient: SFTPClientProtocol {
    var data = Data([1, 2, 3, 4])
    var file = RemoteFile(
        path: "/srv/data", name: "data", kind: .file, size: 4,
        modifiedAt: Date(timeIntervalSince1970: 1), permissions: 0o754, ownerUID: 0, ownerGID: 0)
    var downloads = 0
    var uploads = 0
    var lastPolicy: SFTPEditUploadPolicy?
    private var held = false
    private var losesUpload = false
    private var failsUpload = false
    private var retiresBrowser = false
    private var browserRetired = false
    func hold() { held = true }
    func release() { held = false }
    func loseNextUpload() { losesUpload = true }
    func failNextUpload() { failsUpload = true }
    func retireBrowserOnDownload() { retiresBrowser = true }
    func remoteChange() { file.modifiedAt = file.modifiedAt?.addingTimeInterval(1) }
    func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken, resume: SFTPResumeState,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        uploads += 1
        lastPolicy = resume.snapshot.editPolicy
        if failsUpload {
            failsUpload = false
            throw SFTPError.operation("Permission denied")
        }
        if losesUpload {
            losesUpload = false
            throw SFTPError.connectionLost("test disconnect")
        }
        try lastPolicy?.validate(file)
        while held {
            if cancellation.isCancelled { throw SFTPError.cancelled }
            try await Task.sleep(for: .milliseconds(5))
        }
        try lastPolicy?.validate(file)
        data = try Data(contentsOf: localURL)
        file.size = Int64(data.count)
        remoteChange()
        resume.acknowledge(data)
        resume.recordCommittedVersion(SFTPFileVersion(file))
    }
    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken, resume: SFTPResumeState,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        downloads += 1
        try data.write(to: localURL)
        resume.recordCommittedVersion(SFTPFileVersion(file))
        if retiresBrowser { browserRetired = true }
    }
    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken, progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        downloads += 1
        try data.write(to: localURL)
    }
    func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken, progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws { throw SFTPResumeFailure.unsupported }
    func connect(using configuration: SSHConnectionConfiguration, progress: SSHRouteProgressHandler?) async throws {}
    func disconnect() async {}
    func homeDirectory() async throws -> String { "/" }
    func listDirectory(at path: String) async throws -> [RemoteFile] { [file] }
    func attributes(at path: String) async throws -> RemoteFile? {
        if browserRetired { throw SFTPError.notConnected }
        return path == file.path ? file : nil
    }
    func setPermissions(at path: String, to permissions: UInt32) async throws {}
    func createDirectory(at path: String) async throws {}
    func rename(from source: String, to destination: String, overwrite: Bool) async throws {}
    func removeFile(at path: String) async throws {}
    func removeDirectory(at path: String) async throws {}
}
