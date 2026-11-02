// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite @MainActor
struct CredentialRecoveryTests {
    @Test func terminalWaitsWithoutAnAuthenticationPromptAndStopRejectsLateWake() async throws {
        let (library, host, secrets, availability) = fixture()
        let session = SSHSessionModel(host: host)
        defer { session.disconnect() }
        session.connection.markConnected()
        session.connection.scheduleRecovery(after: "offline") {}
        session.connect(using: library)
        #expect(session.reconnectState?.phase == .waitingForCredentials)
        #expect(session.pendingAuthentication == nil)
        #expect(library.storageError == nil)
        let reads = secrets.reads
        availability.setBlocked(true, by: .systemSleep)
        session.retryReconnectNow()
        #expect(secrets.reads == reads)
        #expect(session.reconnectState?.phase == .waitingForSystem)
        session.stopReconnecting()
        availability.setBlocked(false, by: .systemSleep)
        availability.requestRecheck()
        try await Task.sleep(for: .milliseconds(20))
        #expect(secrets.reads == reads)
        #expect(session.reconnectState == nil)
    }

    @Test func sftpWaitsWithoutClearingAuthenticationAndDisconnectCancelsRecovery() async throws {
        let (library, host, secrets, availability) = fixture()
        let channel = SFTPChannelModel(hostID: host.id)
        defer { channel.disconnect() }
        channel.connection.markConnected()
        channel.connection.scheduleRecovery(after: "offline") {}
        channel.connect(using: library)
        try await wait { channel.reconnectState?.phase == .waitingForCredentials }
        #expect(channel.pendingAuthentication == nil)
        #expect(channel.status == .reconnecting)
        #expect(library.storageError == nil)
        let reads = secrets.reads
        availability.requestRecheck()
        channel.disconnect()
        try await Task.sleep(for: .milliseconds(20))
        #expect(secrets.reads == reads)
        #expect(channel.reconnectState == nil)
    }

    @Test(arguments: [false, true])
    func knownSystemBlockPreventsCredentialReadsBeforeReconnect(_ sftp: Bool) async throws {
        let (library, host, secrets, availability) = fixture()
        availability.setBlocked(true, by: .inactiveSession)
        let terminal = SSHSessionModel(host: host)
        let channel = SFTPChannelModel(hostID: host.id)
        defer {
            terminal.disconnect()
            channel.disconnect()
        }
        let connection = sftp ? channel.connection : terminal.connection
        connection.markConnected()
        connection.scheduleRecovery(after: "offline") {}
        if sftp { channel.connect(using: library) } else { terminal.connect(using: library) }
        #expect(secrets.reads == 0)
        #expect(connection.reconnectState?.phase == .waitingForSystem)
        availability.requestRecheck()
        #expect(secrets.reads == 0)
        availability.setBlocked(false, by: .inactiveSession)
        try await wait { connection.reconnectState?.phase == .waitingForCredentials }
        #expect(secrets.reads > 0)
        #expect(connection.pendingAuthentication == nil)
    }

    @Test(arguments: [false, true])
    func firstConnectionDoesNotStartAutomaticCredentialRetry(_ sftp: Bool) async throws {
        let (library, host, _, _) = fixture()
        let terminal = SSHSessionModel(host: host)
        let channel = SFTPChannelModel(hostID: host.id)
        defer {
            terminal.disconnect()
            channel.disconnect()
        }
        if sftp {
            channel.connect(using: library)
            try await wait { if case .failed = channel.status { true } else { false } }
            #expect(channel.reconnectState == nil)
        } else {
            terminal.connect(using: library)
            guard case .failed = terminal.status else {
                Issue.record("First connection must report the failure without automatic recovery")
                return
            }
            #expect(terminal.reconnectState == nil)
        }
    }

    @Test func sftpDefersWhenTheSystemSleepsDuringAsynchronousAccessResolution() async throws {
        let secrets = CredentialRecoverySecrets()
        let identity = Identity(name: "User", username: "user", credentialRef: "password")
        let hosts = (0..<4).map { index in
            var host = Host(name: "Server \(index)", host: "server.invalid", identityID: identity.id)
            host.createdAt = Date(timeIntervalSince1970: Double(index))
            return host
        }
        let library = HostLibraryModel(hosts: hosts, identities: [identity], secrets: secrets)
        let availability = ConnectionRecoveryAvailability()
        library.recoveryAvailability = availability
        library.hostAccess.entitlement = .loading
        library.resolveInitialHostEntitlement = {
            availability.setBlocked(true, by: .systemSleep)
            library.hostAccess.entitlement = .purchased(.purchased)
        }
        let channel = SFTPChannelModel(hostID: hosts[3].id)
        defer {
            channel.disconnect()
            library.resolveInitialHostEntitlement = nil
        }
        channel.connection.markConnected()
        channel.connection.scheduleRecovery(after: "offline") {}
        channel.connect(using: library)
        try await wait { channel.reconnectState?.phase == .waitingForSystem }
        #expect(secrets.reads == 0)
        #expect(channel.pendingAuthentication == nil)
        #expect(channel.status == .reconnecting)
    }

    @Test(arguments: [false, true])
    func lifecycleSignalsAreHintsAndPreserveIndependentBlockers(_ wakeFirst: Bool) async throws {
        let availability = ConnectionRecoveryAvailability()
        let observer = ConnectionRecoveryActivityObserver(availability: availability)
        let reconnect = SessionReconnectController(sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        reconnect.useAvailability(availability)
        defer { reconnect.stop() }
        var attempts = 0
        observer.receive(.sessionDidResignActive)
        observer.receive(.systemWillSleep)
        reconnect.schedule(after: "offline") { attempts += 1 }
        observer.receive(wakeFirst ? .systemDidWake : .sessionDidBecomeActive)
        observer.receive(.applicationDidBecomeActive)
        #expect(!availability.isAvailable)
        #expect(attempts == 0)
        observer.receive(wakeFirst ? .sessionDidBecomeActive : .systemDidWake)
        observer.receive(.systemDidWake)
        observer.receive(.applicationDidBecomeActive)
        try await wait { attempts == 1 }
        reconnect.schedule(after: "", waitingForCredentials: true) { attempts += 1 }
        #expect(reconnect.state?.phase == .waitingForCredentials)
        // No session transition is required for ordinary sleep/wake.
        observer.receive(.systemWillSleep)
        observer.receive(.systemDidWake)
        try await wait { attempts == 2 }
    }

    private func fixture() -> (HostLibraryModel, Host, CredentialRecoverySecrets, ConnectionRecoveryAvailability) {
        let secrets = CredentialRecoverySecrets()
        secrets.unavailable = true
        let identity = Identity(name: "User", username: "user", credentialRef: "password")
        let host = Host(name: "Server", host: "server.invalid", identityID: identity.id)
        let library = HostLibraryModel(hosts: [host], identities: [identity], secrets: secrets)
        let availability = ConnectionRecoveryAvailability()
        library.recoveryAvailability = availability
        return (library, host, secrets, availability)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}

nonisolated final class CredentialRecoverySecrets: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var blocked = false
    private var readCount = 0
    private let backing = InMemorySecretStore()
    var unavailable: Bool {
        get { lock.withLock { blocked } }
        set { lock.withLock { blocked = newValue } }
    }
    var reads: Int { lock.withLock { readCount } }
    func string(for account: String, storage: PasswordStorage) throws -> String? {
        try lock.withLock {
            readCount += 1
            if blocked { throw SSHCredentialAccessUnavailable() }
            return try backing.string(for: account, storage: storage)
        }
    }
    func keyCredential(for account: String, storage: KeyStorage) throws -> StoredSSHKeyCredential? {
        try lock.withLock {
            readCount += 1
            if blocked { throw SSHCredentialAccessUnavailable() }
            return try backing.keyCredential(for: account, storage: storage)
        }
    }
    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {
        try backing.setString(value, for: account, storage: storage)
    }
    func setKeyCredential(_ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage) throws {
        try backing.setKeyCredential(value, for: account, storage: storage)
    }
    func removePassword(_ account: String, storage: PasswordStorage) throws {
        try backing.removePassword(account, storage: storage)
    }
    func removeKeyCredential(_ account: String, storage: KeyStorage) throws {
        try backing.removeKeyCredential(account, storage: storage)
    }
}
