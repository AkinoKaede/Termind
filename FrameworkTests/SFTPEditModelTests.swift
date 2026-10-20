// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct SFTPEditModelTests {
    @Test func onlyChangedFilesAreVisibleAndRevertingHidesThem() {
        let model = SFTPEditModel()
        let hostID = UUID()
        let file = remoteFile()
        let id = model.register(hostID: hostID, file: file, localURL: URL(filePath: "/tmp/file"), digest: "original")
        #expect(model.modifiedFiles(for: hostID).isEmpty)
        model.update(id) { $0.currentDigest = "edited" }
        #expect(model.modifiedFiles(for: hostID).map(\.id) == [id])
        #expect(model.modifiedFiles(for: UUID()).isEmpty)
        model.update(id) { $0.currentDigest = "original" }
        #expect(!model.hasPendingChanges)
    }

    @Test func uploadingOneVersionDoesNotClearLaterChanges() {
        let model = SFTPEditModel()
        let hostID = UUID()
        let file = remoteFile()
        let id = model.register(hostID: hostID, file: file, localURL: URL(filePath: "/tmp/file"), digest: "one")
        model.update(id) {
            $0.currentDigest = "three"
            $0.transferID = UUID()
        }
        model.didUpload(id, digest: "two", baseline: SFTPFileVersion(file))
        #expect(model.file(id)?.isModified == true)
        #expect(model.file(id)?.transferID == nil)
        model.didUpload(id, digest: "three", baseline: SFTPFileVersion(file))
        #expect(!model.hasPendingChanges)
    }

    @Test func reopeningDoesNotReplaceAnEditedCopyAndInvalidationRetainsIt() {
        let model = SFTPEditModel()
        let hostID = UUID()
        let id = model.register(hostID: hostID, file: remoteFile(), localURL: URL(filePath: "/tmp/one"), digest: "one")
        model.update(id) { $0.currentDigest = "two" }
        let duplicate = model.register(
            hostID: hostID, file: remoteFile(), localURL: URL(filePath: "/tmp/new"), digest: "new")
        #expect(id == duplicate)
        #expect(model.file(id)?.localURL.path == "/tmp/one")
        model.invalidate(hostID: hostID)
        #expect(model.modifiedFiles(for: hostID).count == 1)
        #expect(model.file(id)?.isInvalidated == true)
    }

    @Test func uploadGuardRejectsChangedMissingAndNonregularDestinations() throws {
        let original = remoteFile()
        let policy = SFTPEditUploadPolicy(expected: SFTPFileVersion(original), permissions: 0o755)
        try policy.validate(original)
        for kind in [RemoteFile.Kind.symbolicLink, .directory, .special, .unknown] {
            var replacement = original
            replacement.kind = kind
            #expect(throws: SFTPEditFailure.self) { try policy.validate(replacement) }
        }
        var changed = original
        changed.modifiedAt = Date(timeIntervalSince1970: 2)
        #expect(throws: SFTPEditFailure.self) { try policy.validate(changed) }
        #expect(throws: SFTPEditFailure.self) { try policy.validate(nil) }
        try SFTPEditUploadPolicy(expected: nil, permissions: 0o755).validate(nil)
    }

    private func remoteFile() -> RemoteFile {
        RemoteFile(
            path: "/srv/file", name: "file", kind: .file, size: 4,
            modifiedAt: Date(timeIntervalSince1970: 1), permissions: 0o755, ownerUID: 0, ownerGID: 0)
    }
}
