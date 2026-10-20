// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite @MainActor
struct DesktopAuthenticationSubmissionTests {
    @Test(arguments: [ConnectionHistoryEntry.Kind.ssh, .sftp])
    func failedIdentitySaveRepromptsWithoutChangingTheLibrary(kind: ConnectionHistoryEntry.Kind) throws {
        let key = protectedKey()
        let identity = Identity(
            name: "Unavailable", username: "deploy", credentialRef: "missing-password", keyID: key.id)
        let host = Host(name: "Server", host: "server.invalid")
        let store = HostLibraryModel(
            hosts: [host], keys: [key], identities: [identity], secrets: InMemorySecretStore())
        let session = DesktopAuthenticationSession(kind: kind, host: host)
        defer { session.disconnect() }
        session.ssh?.connect(using: store)
        session.sftp?.connect(using: store)

        session.submit(
            identityID: identity.id, username: "ignored", password: "replacement",
            keyID: nil, save: true, store: store)

        let prompt = try #require(session.prompt)
        #expect(prompt.failureMessage?.isEmpty == false)
        #expect(store.host(host.id) == host)
        #expect(store.identity(identity.id) == identity)
        if let ssh = session.ssh {
            #expect(ssh.status == .disconnected)
            #expect(prompt.username == "deploy")
            #expect(prompt.selectedKeyID == key.id)
        }
        if let sftp = session.sftp {
            #expect(sftp.status == .disconnected)
            #expect(sftp.operationError == prompt.failureMessage)
        }
    }

    @Test(arguments: [ConnectionHistoryEntry.Kind.ssh, .sftp], [false, true])
    func unsavedInputPreservesSelectionAndPassphraseContinuation(kind: ConnectionHistoryEntry.Kind, selected: Bool)
        throws
    {
        let key = protectedKey()
        let identity = Identity(name: "Deploy", username: "  saved-user \n", keyID: key.id)
        let host = Host(name: "Server", host: "server.invalid")
        let store = HostLibraryModel(hosts: [host], keys: [key], identities: [identity])
        let session = DesktopAuthenticationSession(kind: kind, host: host)
        defer { session.disconnect() }

        session.submit(
            identityID: selected ? identity.id : nil, username: "  manual-user \n", password: "one-use",
            keyID: selected ? UUID() : key.id, save: false, store: store)

        let prompt = try #require(session.prompt)
        #expect(prompt.requiresPassphrase)
        #expect(prompt.username == (selected ? "saved-user" : "manual-user"))
        #expect(prompt.selectedKeyID == key.id)
        #expect(prompt.selectedIdentityID == (selected ? identity.id : nil))
        #expect(store.host(host.id) == host)
        #expect(store.identity(identity.id) == identity)

        session.submit(
            identityID: nil, username: "ignored", password: "ignored", passphrase: "",
            keyID: UUID(), save: true, store: store)
        #expect(session.prompt?.id == prompt.id)
        #expect(store.host(host.id) == host)
        #expect(store.identities == [identity])
    }

    @Test(arguments: [ConnectionHistoryEntry.Kind.ssh, .sftp])
    func blankUsernameLeavesTheOriginalPromptAndStoreUntouched(kind: ConnectionHistoryEntry.Kind) throws {
        let host = Host(name: "Server", host: "server.invalid")
        let store = HostLibraryModel(hosts: [host])
        let session = DesktopAuthenticationSession(kind: kind, host: host)
        defer { session.disconnect() }
        let prompt = try #require(session.prompt)

        session.submit(username: " \n\t ", password: "unused", save: true, store: store)

        #expect(session.prompt?.id == prompt.id)
        #expect(store.host(host.id) == host)
        #expect(store.identities.isEmpty)
    }

    @Test(arguments: [ConnectionHistoryEntry.Kind.ssh, .sftp])
    func clearingSavedPasswordDeletesItAndContinuesWithTheKey(kind: ConnectionHistoryEntry.Kind) throws {
        let key = protectedKey()
        let secrets = InMemorySecretStore()
        let identity = Identity(name: "Deploy", username: "deploy", credentialRef: "password", keyID: key.id)
        let host = Host(name: "Server", host: "server.invalid")
        let store = HostLibraryModel(hosts: [host], keys: [key], identities: [identity], secrets: secrets)
        try secrets.setString("old", for: identity.credentialRef, storage: identity.passwordStorage)
        let session = DesktopAuthenticationSession(kind: kind, host: host)
        defer { session.disconnect() }

        session.submit(identityID: identity.id, username: "ignored", password: "", save: true, store: store)

        #expect(store.host(host.id)?.identityID == identity.id)
        let updatedIdentity = try #require(store.identity(identity.id))
        #expect(try store.passwordCredential(for: updatedIdentity) == nil)
        #expect(session.prompt?.requiresPassphrase == true)
        #expect(session.prompt?.failureMessage == nil)
    }

    @Test(arguments: [false, true])
    func temporarySSHHostCanContinueWithOrWithoutSaving(_ save: Bool) throws {
        let key = protectedKey()
        let host = Host(name: "Temporary", host: "temporary.invalid")
        let store = HostLibraryModel(keys: [key])
        let session = DesktopAuthenticationSession(kind: .ssh, host: host)
        defer { session.disconnect() }

        session.submit(username: " deploy ", password: "one-use", keyID: key.id, save: save, store: store)

        let prompt = try #require(session.prompt)
        #expect(prompt.host.id == host.id)
        #expect(prompt.username == "deploy")
        #expect(prompt.requiresPassphrase)
        #expect((store.host(host.id) != nil) == save)
        #expect(store.identities.count == (save ? 1 : 0))
        if save {
            let saved = try #require(store.host(host.id))
            #expect(prompt.host.identityID == saved.identityID)
            #expect(store.identity(for: saved)?.username == "deploy")
            #expect(store.identity(for: saved)?.isHostCustom == true)
            #expect(store.reusableIdentities.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func sftpPassphraseContinuationSavesOnlyWhenRequested(_ save: Bool) throws {
        let key = protectedKey()
        let secrets = InMemorySecretStore()
        let identity = Identity(name: "Deploy", username: "deploy", keyID: key.id)
        let host = Host(name: "Server", host: "server.invalid", identityID: identity.id)
        let library = HostLibraryModel(hosts: [host], keys: [key], identities: [identity], secrets: secrets)
        try secrets.setKeyCredential(
            .software(.init(privateKey: "encrypted")), for: key.credentialRef, storage: key.storage)
        let app = AppModel(hosts: library)
        let channel = SFTPChannelModel(hostID: host.id)
        defer { channel.disconnect() }
        channel.pendingAuthentication = SSHAuthenticationPrompt(
            host: host, selectedIdentityID: identity.id, username: identity.username,
            selectedKeyID: key.id, requiresPassphrase: true)

        channel.continueAuthentication(
            identityID: identity.id, username: identity.username, password: nil,
            passphrase: "saved", keyID: key.id, save: save, using: app.hostLibrary)

        #expect(channel.pendingAuthentication == nil)
        guard
            case .software(let credential)? = try secrets.keyCredential(
                for: key.credentialRef, storage: key.storage)
        else {
            Issue.record("The protected key must remain available")
            return
        }
        #expect(credential.passphrase == (save ? "saved" : nil))
        #expect(library.host(host.id) == host)
    }

    private func protectedKey() -> SSHKeyRef {
        SSHKeyRef(label: "Protected", publicKey: "ssh-ed25519 fixture", hasPassphrase: true)
    }
}

/// A pending protected-key prompt keeps these entry-point tests entirely local:
/// continuing without its passphrase cannot open a transport.
@MainActor
private final class DesktopAuthenticationSession {
    let ssh: SSHSessionModel?
    let sftp: SFTPChannelModel?
    var prompt: SSHAuthenticationPrompt? { ssh?.pendingAuthentication ?? sftp?.pendingAuthentication }

    init(kind: ConnectionHistoryEntry.Kind, host: Host) {
        ssh = kind == .ssh ? SSHSessionModel(host: host) : nil
        sftp = kind == .sftp ? SFTPChannelModel(hostID: host.id) : nil
        let prompt = SSHAuthenticationPrompt(host: host, username: "")
        ssh?.pendingAuthentication = prompt
        sftp?.pendingAuthentication = prompt
    }

    func submit(
        identityID: UUID? = nil, username: String, password: String?, passphrase: String? = nil,
        keyID: UUID? = nil, save: Bool, store: HostLibraryModel
    ) {
        ssh?.continueAuthentication(
            identityID: identityID, username: username, password: password, passphrase: passphrase,
            keyID: keyID, save: save, using: store)
        sftp?.continueAuthentication(
            identityID: identityID, username: username, password: password, passphrase: passphrase,
            keyID: keyID, save: save, using: store)
    }

    func disconnect() {
        ssh?.disconnect()
        sftp?.disconnect()
    }
}
