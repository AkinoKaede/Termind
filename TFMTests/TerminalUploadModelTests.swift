// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite @MainActor
struct TerminalUploadModelTests {
    @Test func remountingKeepsUploadStateWithTheSessionAndDisconnectClearsIt() {
        let session = SSHSessionModel(hostID: UUID(), title: "Upload")
        let uploads = session.terminalUpload
        let connections = RemoteConnectionCoordinator()
        let transfers = SFTPTransferCoordinator(store: HostLibraryModel()) {
            Issue.record("Rejected upload must not open a transfer client")
            return connections.makeSFTPClient()
        }
        #expect(
            !uploads.receiveRemoteDrop(
                Data("invalid".utf8), connections: connections, transfers: transfers))
        #expect(uploads.notice != nil)

        let oldBinding = session.terminalViewOwner.bindUpload(action: {}, isAvailable: { false })
        let newBinding = session.terminalViewOwner.bindUpload(action: {}, isAvailable: { false })
        #expect(!session.terminalViewOwner.unbindUpload(oldBinding))
        #expect(session.terminalUpload === uploads)
        #expect(uploads.notice != nil)
        #expect(session.terminalViewOwner.unbindUpload(newBinding))
        #expect(uploads.notice != nil)

        session.disconnect()
        #expect(uploads.notice == nil)
        #expect(!uploads.hasConflict)
        #expect(transfers.sftpTransfers.isEmpty)
    }

    @Test func retiredPickerTargetCannotStartAnotherSessionUpload() {
        let session = SSHSessionModel(hostID: UUID(), title: "Upload")
        let uploads = session.terminalUpload
        let connections = RemoteConnectionCoordinator()
        let transfers = SFTPTransferCoordinator(store: HostLibraryModel()) {
            Issue.record("Retired picker must not open a transfer client")
            return connections.makeSFTPClient()
        }
        let target = TerminalUploadModel.Target(generation: UUID(), destination: "/old-session")
        let accepted = uploads.receiveFiles(
            [URL(filePath: "/tmp/retired-upload")], selectedTarget: target,
            connections: connections, transfers: transfers)
        #expect(!accepted)
        #expect(uploads.notice == nil)
        #expect(!uploads.hasConflict)
        #expect(transfers.sftpTransfers.isEmpty)
    }
}
