// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import Testing

@testable import Termind

@Suite @MainActor
struct ExternalConnectionURLTests {
    @Test func externalSSHOpensATemporaryWorkspaceWithoutSaving() throws {
        let app = AppModel(hosts: HostLibraryModel())
        let window = WindowModel()
        defer { app.shutdownForTermination() }

        app.openExternalConnection(
            try #require(
                URL(
                    string:
                        "ssh://deploy;fingerprint=ssh-rsa-00-11-22-33-44-55-66-77-88-99-aa-bb-cc-dd-ee-ff@example.invalid:2222"
                )),
            in: window)

        let session = try #require(window.selectedWorkspace?.focusedPane.sshSession)
        #expect(session.isExternalTemporaryConnection)
        #expect(session.connectionRoute?.hosts.first?.host == "example.invalid")
        #expect(session.connectionRoute?.hosts.first?.port == 2222)
        #expect(session.connectionOrigin.hostKeyConstraints[session.hostID]?.legacyMD5.count == 16)
        #expect(app.hostLibrary.hosts.isEmpty)
    }

    @Test func telnetPasswordRequiresConfirmationBeforeOpening() throws {
        let app = AppModel(hosts: HostLibraryModel())
        let window = WindowModel()
        defer { app.shutdownForTermination() }

        app.openExternalConnection(
            try #require(URL(string: "telnet://operator:secret@example.invalid")),
            in: window)

        #expect(window.pendingExternalConnection?.advisoryPassword == "secret")
        #expect(window.workspaces.isEmpty)
        app.confirmExternalConnection(in: window)
        #expect(window.pendingExternalConnection == nil)
        #expect(window.selectedWorkspace?.focusedPane.telnetSession != nil)
        #expect(app.hostLibrary.hosts.isEmpty)
    }
}
