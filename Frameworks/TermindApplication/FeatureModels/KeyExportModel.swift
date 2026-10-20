// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Observation
import TermindDomain

import struct TermindDomain.Host

@MainActor
@Observable
public final class KeyExportModel {
    public enum Phase: Equatable {
        case editing, preparing, authenticating, exporting, succeeded
        case failed(String)
        case attachmentFailed(String)
    }

    public let keyID: SSHKeyRef.ID
    public var key: SSHKeyRef? { library.key(keyID) }
    public var hostID: Host.ID? {
        didSet { if oldValue != hostID { cancel() } }
    }
    public var exportPassphrase = ""
    public var saveExportPassphrase = false
    public private(set) var passphraseError: String?
    public var options: KeyExportOptions
    public let connection = RemoteSessionConnectionController()
    public var journey: ConnectionJourney { connection.journey }
    public var operationID: UUID { generation }
    public private(set) var phase: Phase = .editing
    public private(set) var authenticationPrompt: SSHAuthenticationPrompt?
    public private(set) var didExport = false
    public private(set) var executionStarted = false
    private let library: HostLibraryModel
    private let services: KeyExportServices
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var session: (any KeyExportSession)?
    private var submissions: [Host.ID: SSHAuthenticationSubmission] = [:]
    private var proxySubmissions: [Host.ID: SSHProxyAuthenticationSubmission] = [:]
    private var derivedPublicKey: String?
    private var derivationPassphrase: SSHSecret?
    private var savesDerivationPassphrase = false
    private var derivationPassphraseToSave: String?
    private var username = ""
    private var targetSnapshot: Host?
    private var keySnapshot: SSHKeyRef?
    private var routeSnapshot: [Host] = []

    public init(key: SSHKeyRef, library: HostLibraryModel, services: KeyExportServices) {
        keyID = key.id
        self.library = library
        self.services = services
        options = KeyExportOptions(script: KeyExportOptions.defaultScript(keyName: key.label))
    }

    public var isBusy: Bool {
        switch phase {
        case .preparing, .authenticating, .exporting: true
        default: false
        }
    }
    public var needsExportPassphrase: Bool {
        guard derivedPublicKey == nil || keySnapshot != key, let key,
            key.publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return passphraseError != nil || (key.hasPassphrase && library.requiresPassphraseEntry(for: key))
    }
    public var canStart: Bool {
        !isBusy && !didExport && key != nil && hosts.contains { $0.id == hostID } && options.isValid
            && (!needsExportPassphrase || !exportPassphrase.isEmpty)
    }
    public var hosts: [Host] { library.hosts(matching: "", for: .keyExport) }

    public func start() {
        guard canStart, task == nil, let hostID, let host = library.host(hostID), let key else { return }
        if keySnapshot != key { derivedPublicKey = nil }
        targetSnapshot = host
        keySnapshot = key
        routeSnapshot = library.route(for: host)
        executionStarted = false
        derivationPassphrase = exportPassphrase.isEmpty ? nil : SSHSecret(exportPassphrase)
        derivationPassphraseToSave = saveExportPassphrase && !exportPassphrase.isEmpty ? exportPassphrase : nil
        savesDerivationPassphrase = saveExportPassphrase
        exportPassphrase = ""
        passphraseError = nil
        journey.begin(
            host: host, route: routeSnapshot, purpose: .keyExport, username: library.identity(for: host)?.username)
        launch()
    }

    public func retry() {
        guard !isBusy else { return }
        if didExport {
            attach()
        } else {
            start()
        }
    }

    public func editOptions() {
        guard case .failed = phase else { return }
        connection.disconnect()
    }

    public func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        if let session { Task { await session.disconnect() } }
        session = nil
        authenticationPrompt = nil
        connection.disconnect()
        clearSecrets()
        derivedPublicKey = nil
        didExport = false
        executionStarted = false
        phase = .editing
        exportPassphrase = ""
        passphraseError = nil
        targetSnapshot = nil
        keySnapshot = nil
        routeSnapshot = []
    }

    public func acceptHostKey(_ observation: SSHHostKeyObservation, operationID: UUID, remember: Bool) {
        guard operationID == generation else { return }
        guard isBusy, snapshotsAreCurrent else {
            cancel()
            return
        }
        if remember {
            connection.trustHostKey(observation, using: library)
        } else {
            _ = connection.useTemporaryHostKey(observation)
        }
    }

    public func submitAuthentication(
        promptID: UUID, identityID: Identity.ID?, username: String, password: String?,
        passphrase: String?, keyID: SSHKeyRef.ID?, save: Bool
    ) {
        guard let prompt = authenticationPrompt, prompt.id == promptID, snapshotsAreCurrent, task == nil else { return }
        do {
            if prompt.isProxy {
                let submission = SSHProxyAuthenticationSubmission(
                    username: username, password: password, identityID: identityID)
                if save {
                    _ = try library.saveProxyAuthentication(
                        submission, for: library.host(prompt.host.id) ?? prompt.host,
                        selectedIdentity: identityID.flatMap(library.identity),
                        suppliedPassword: password)
                    refreshRouteSnapshot()
                }
                proxySubmissions[prompt.host.id] = submission
            } else if prompt.requiresPassphrase {
                submissions[prompt.host.id] = try library.passphraseSubmission(
                    for: prompt, existing: submissions[prompt.host.id], passphrase: passphrase, save: save)
            } else {
                let identity = identityID.flatMap(library.identity)
                let name = (identity?.username ?? username).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw TermindSSHError.missingUsername }
                let selectedKey = identity?.keyID ?? keyID
                if save {
                    let saved = identity ?? Identity(name: name, username: name, keyID: selectedKey)
                    try library.upsert(saved, passwordUpdate: password.map(IdentityPasswordUpdate.replace) ?? .keep)
                    guard var host = library.host(prompt.host.id) else { throw TermindSSHError.missingCredential }
                    host.identityID = saved.id
                    guard library.saveHost(host) else {
                        throw TermindSSHError.library(library.storageError ?? String(localized: "Unable to Save"))
                    }
                    refreshRouteSnapshot()
                }
                submissions[prompt.host.id] = SSHAuthenticationSubmission(
                    username: name, password: password, passphrase: passphrase, keyID: selectedKey,
                    identityID: identityID)
            }
            authenticationPrompt = nil
            journey.resume()
            launch()
        } catch {
            var failed = prompt
            failed.failureMessage = error.localizedDescription
            authenticationPrompt = failed
        }
    }

    private func refreshRouteSnapshot() {
        if let hostID, let host = library.host(hostID) {
            targetSnapshot = host
            routeSnapshot = library.route(for: host)
        }
    }

    private var snapshotsAreCurrent: Bool {
        keySnapshot == key && targetSnapshot?.id == hostID
            && routeSnapshot.allSatisfy { old in library.host(old.id)?.hasSameConnectionRoute(as: old) == true }
    }

    private func check(_ id: UUID) throws {
        try Task.checkCancellation()
        guard generation == id, snapshotsAreCurrent else { throw CancellationError() }
    }

    private func launch() {
        guard task == nil, let host = targetSnapshot, let key = keySnapshot else { return }
        let id = UUID()
        generation = id
        phase = .preparing
        let options = options
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try check(id)
                guard options.isValid, library.keyExportUnavailableReason(for: host) == nil else {
                    throw HostProtocolUnavailableError(useCase: .keyExport)
                }
                let publicKey: String
                if !key.publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    publicKey = key.publicKey
                } else if let derivedPublicKey {
                    publicKey = derivedPublicKey
                } else {
                    guard let credential = try library.keySecretCredential(for: key) else {
                        throw TermindSSHError.missingCredential
                    }
                    defer { credential.clearSecrets() }
                    if key.hasPassphrase && !credential.hasSavedPassphrase && derivationPassphrase == nil {
                        requestDerivationPassphrase(failure: String(localized: "Passphrase required"))
                        task = nil
                        return
                    }
                    let passphrase = derivationPassphrase
                    derivationPassphrase = nil
                    defer { passphrase?.clear() }
                    do {
                        publicKey = try await services.derivePublicKey(key, credential, passphrase)
                    } catch {
                        try check(id)
                        guard key.hasPassphrase else { throw error }
                        clearSecrets()
                        requestDerivationPassphrase(failure: error.localizedDescription)
                        task = nil
                        return
                    }
                    try check(id)
                    if savesDerivationPassphrase, let derivationPassphraseToSave {
                        try library.saveKeyPassphrase(derivationPassphraseToSave, for: key.id)
                    }
                    derivationPassphraseToSave = nil
                    savesDerivationPassphrase = false
                    self.derivedPublicKey = publicKey
                }
                if !key.certificate.isEmpty { _ = try SSHUserCertificate.parse(key.certificate, matching: publicKey) }
                try check(id)
                if let pending = proxySubmissions.firstHostRequiringProxyPassword(in: routeSnapshot) {
                    requestAuthentication(
                        .proxyAuthentication(
                            hostID: pending.id, serverChallenge: false,
                            message: String(localized: "The proxy password is unavailable.")))
                    task = nil
                    return
                }
                if let pending = submissions.firstHostRequiringPassword(in: routeSnapshot) {
                    requestAuthentication(
                        .routeHost(
                            hostID: pending.id, authentication: true, serverChallenge: false, hostKey: false,
                            message: TermindSSHError.missingCredential.localizedDescription))
                    task = nil
                    return
                }
                if let pending = submissions.firstHostRequiringPassphrase(
                    in: routeSnapshot, key: library.key, requiresEntry: library.requiresPassphraseEntry)
                {
                    requestAuthentication(
                        .routeHost(
                            hostID: pending.id, authentication: true, serverChallenge: false, hostKey: false,
                            message: TermindSSHError.keyPassphraseRequired.localizedDescription))
                    task = nil
                    return
                }
                let attemptSubmissions = submissions.takeAuthenticationSecrets()
                let attemptProxies = proxySubmissions.takeProxyAuthenticationSecrets()
                let preparation = try library.prepareSSHConnection(
                    for: host, submissions: attemptSubmissions, proxySubmissions: attemptProxies,
                    temporaryHostKeys: connection.temporaryHostKeys)
                let configuration = try await preparation.resolve(trustPolicy: .allowChallenge)
                defer { configuration.clearSecrets() }
                try check(id)
                username = configuration.username
                phase = .authenticating
                let request = SSHConnectionRequest(
                    configuration: configuration,
                    authorizeHostKey: { [weak self] challenge in
                        guard let self else { return .reject }
                        return try await self.authorize(challenge, generation: id)
                    },
                    keyboardInteractive: { [weak self] challenge in
                        guard let self else { throw CancellationError() }
                        return try await self.answer(challenge, generation: id)
                    },
                    securityKeySigning: { [weak self] request in
                        guard let self else { throw CancellationError() }
                        return try await self.sign(request, generation: id)
                    })
                let opened = try await services.connect(
                    request,
                    connection.progressHandler(attemptID: id, isCurrent: { [weak self] in self?.generation == $0 }))
                do { try check(id) } catch {
                    await opened.disconnect()
                    throw error
                }
                session = opened
                phase = .exporting
                executionStarted = true
                do {
                    try await opened.install(publicKey: publicKey, options: options)
                    await opened.disconnect()
                } catch {
                    await opened.disconnect()
                    throw error
                }
                try check(id)
                session = nil
                task = nil
                didExport = true
                clearSecrets()
                derivedPublicKey = nil
                connection.disconnect()
                attach()
            } catch {
                guard generation == id else { return }
                session = nil
                task = nil
                if error is CancellationError {
                    cancel()
                } else if !executionStarted, let ssh = error as? TermindSSHError,
                    ssh.isLocalAuthenticationRequirement || ssh.shouldRequestAuthentication
                {
                    requestAuthentication(ssh)
                } else {
                    clearSecrets()
                    let message =
                        executionStarted
                        ? String(
                            localized:
                                "The export did not complete. Check the remote file before running the script again.")
                            + "\n" + error.localizedDescription
                        : error.localizedDescription
                    phase = .failed(message)
                    journey.fail(message)
                }
            }
        }
    }

    private func authorize(_ challenge: SSHHostKeyChallenge, generation: UUID) async throws -> SSHHostKeyDecision {
        try check(generation)
        let decision = await connection.authorizeHostKey(challenge)
        try check(generation)
        return decision
    }

    private func answer(_ challenge: SSHKeyboardInteractiveChallenge, generation: UUID) async throws -> [String] {
        try check(generation)
        let answers = try await connection.answerKeyboardInteractive(challenge)
        try check(generation)
        return answers
    }

    private func sign(_ request: SecurityKeySigningRequest, generation: UUID) async throws -> SecurityKeyAssertion {
        try check(generation)
        let assertion = try await connection.signWithSecurityKey(request)
        try check(generation)
        return assertion
    }

    private func requestDerivationPassphrase(failure: String) {
        passphraseError = failure
        phase = .editing
        journey.hide()
    }

    private func requestAuthentication(_ error: TermindSSHError) {
        guard let host = library.host(error.routeHostID ?? hostID ?? UUID()) else {
            clearSecrets()
            phase = .failed(error.localizedDescription)
            journey.fail(error.localizedDescription)
            return
        }
        if error.isProxyAuthentication {
            authenticationPrompt = SSHAuthenticationPromptResolver.proxy(
                for: host, using: library, submission: proxySubmissions[host.id],
                failureMessage: error.localizedDescription,
                mode: error.isServerAuthenticationChallenge ? .serverChallenge : .localIdentity)
            journey.waitForProxyAuthentication(at: host.id, failure: error.localizedDescription)
        } else {
            authenticationPrompt = SSHAuthenticationPromptResolver.host(
                host, using: library, submission: submissions[host.id], failureMessage: error.localizedDescription,
                mode: error.isServerAuthenticationChallenge ? .serverChallenge : .localIdentity)
            if authenticationPrompt?.requiresPassphrase == true {
                journey.waitForLocalPassphrase(at: host.id, failure: error.localizedDescription)
            } else if error.isServerAuthenticationChallenge {
                journey.waitForAuthentication(at: host.id, failure: error.localizedDescription)
            } else {
                journey.waitForLocalIdentity(at: host.id, failure: error.localizedDescription)
            }
        }
        phase = .authenticating
    }

    private func attach() {
        guard didExport, let hostID else { return }
        do {
            guard snapshotsAreCurrent else { throw TermindSSHError.missingCredential }
            try library.attachExportedKey(keyID, to: hostID, username: username)
            phase = .succeeded
        } catch {
            phase = .attachmentFailed(error.localizedDescription)
        }
    }

    private func clearSecrets() {
        for id in submissions.keys { submissions[id]?.clearSecrets() }
        for id in proxySubmissions.keys { proxySubmissions[id]?.clearSecrets() }
        submissions.removeAll()
        proxySubmissions.removeAll()
        derivationPassphrase?.clear()
        derivationPassphrase = nil
        derivationPassphraseToSave = nil
        savesDerivationPassphrase = false
    }
}
