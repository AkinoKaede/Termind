import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct KeyExportTests {
    @Test func openingAndEmptySelectionNeverInstallAnything() async {
        let fixture = KeyExportFixture()
        let recorder = KeyExportRecorder()
        let model = fixture.model(recorder)
        #expect(model.selected.isEmpty)
        await model.export(to: [])
        #expect(await recorder.calls.isEmpty)
        #expect(!model.isFinished)
    }

    @Test func missingPublicKeyCannotBeExported() async {
        let fixture = KeyExportFixture()
        let recorder = KeyExportRecorder()
        let model = KeyExportModel(
            keys: [SSHKeyRef(label: "Missing")], credentials: fixture.credentials,
            services: KeyExportServices(install: recorder.install))
        await model.export(to: [fixture.alpha.id])
        #expect(await recorder.calls.isEmpty)
    }

    @Test func submitRevalidatesChangedHostCapabilities() async {
        let fixture = KeyExportFixture()
        let recorder = KeyExportRecorder()
        let model = fixture.model(recorder)
        var changed = fixture.alpha
        changed.sshEnabled = false
        changed.telnetEnabled = true
        #expect(fixture.library.saveHost(changed))
        await model.export(to: [fixture.alpha.id, fixture.beta.id])
        #expect(model.isFinished)
        if case .failed = model.states[fixture.alpha.id] {} else { Issue.record("Expected unavailable host failure") }
        #expect(model.states[fixture.beta.id] == .succeeded)
        #expect(await recorder.calls.map(\.hostID) == [fixture.beta.id])
    }

    @Test func preparationFailureDoesNotPreventOtherDestinations() async {
        let fixture = KeyExportFixture()
        let recorder = KeyExportRecorder()
        let model = fixture.model(recorder)
        var changed = fixture.alpha
        changed.jumpHostID = fixture.untrusted.id
        #expect(fixture.library.saveHost(changed))
        await model.export(to: [fixture.alpha.id, fixture.beta.id])
        if case .failed = model.states[fixture.alpha.id] {} else { Issue.record("Expected route preparation failure") }
        #expect(model.states[fixture.beta.id] == .succeeded)
        #expect(await recorder.calls.map(\.hostID) == [fixture.beta.id])
    }

    @Test func installsOnlyTheChosenPublicKeyAndReportsPartialFailure() async {
        let fixture = KeyExportFixture()
        let recorder = KeyExportRecorder(failingHost: fixture.beta.id)
        let model = fixture.model(recorder)
        await model.export(to: [fixture.alpha.id, fixture.beta.id])
        let calls = await recorder.calls
        #expect(Set(calls.map(\.hostID)) == [fixture.alpha.id, fixture.beta.id])
        #expect(calls.allSatisfy { $0.publicKeys == [fixture.key.publicKey] && $0.names == [fixture.key.label] })
        #expect(calls.allSatisfy { $0.username == "deploy" && !$0.trustedKeys.isEmpty })
        #expect(model.states[fixture.alpha.id] == .succeeded)
        #expect(model.states[fixture.beta.id] == .failed("Fixture export failure"))
        #expect(model.isFinished && !model.isExporting)
    }

    @Test func exportsEverySelectedKeyOncePerRemainingHost() async {
        let fixture = KeyExportFixture()
        let recorder = KeyExportRecorder()
        let keys = [fixture.key, SSHKeyRef(label: "Backup", publicKey: "ssh-ed25519 backup-public-key")]
        let model = KeyExportModel(
            keys: keys, credentials: fixture.credentials, services: KeyExportServices(install: recorder.install))
        model.updateSelection([fixture.alpha.id, fixture.beta.id])
        fixture.library.projectHostDeletion(fixture.alpha.id)
        await model.export(to: [fixture.alpha.id, fixture.beta.id, fixture.beta.id])
        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls.first?.hostID == fixture.beta.id)
        #expect(calls.first?.publicKeys == keys.map(\.publicKey))
        #expect(calls.first?.names == keys.map(\.label))
        #expect(model.targets.map(\.id) == [fixture.beta.id])
        #expect(model.selected == [fixture.beta.id])
        #expect(model.states == [fixture.beta.id: .succeeded])
    }

    @Test func removedDestinationsAndEmptyKeyBatchesNeverStartAnExport() async {
        let fixture = KeyExportFixture()
        let recorder = KeyExportRecorder()
        let empty = KeyExportModel(
            keys: [], credentials: fixture.credentials, services: KeyExportServices(install: recorder.install))
        await empty.export(to: [fixture.alpha.id])
        #expect(!empty.isExporting && !empty.isFinished)
        let model = fixture.model(recorder)
        fixture.library.projectHostDeletion(fixture.alpha.id)
        await model.export(to: [fixture.alpha.id])
        #expect(!model.isExporting && !model.isFinished)
        #expect(model.selected.isEmpty && model.targets.isEmpty)
        #expect(await recorder.calls.isEmpty)
    }

    @Test func revokedTrustFailsWithoutConnectingAndDoesNotBlockOtherHosts() async {
        let fixture = KeyExportFixture()
        let recorder = KeyExportRecorder()
        let model = fixture.model(recorder)
        let trust = fixture.library.knownHosts.filter { $0.hostname == fixture.alpha.host }
        #expect(fixture.library.deleteKnownHosts(Set(trust.map(\.id))))
        await model.export(to: [fixture.alpha.id, fixture.beta.id, fixture.untrusted.id])
        #expect(await recorder.calls.map(\.hostID) == [fixture.beta.id])
        if case .failed = model.states[fixture.alpha.id] {} else { Issue.record("Expected revoked trust failure") }
        if case .failed = model.states[fixture.untrusted.id] {} else { Issue.record("Expected untrusted host failure") }
        #expect(model.states[fixture.beta.id] == .succeeded)
    }

    @Test func runningExportRejectsDuplicateSubmissions() async {
        let fixture = KeyExportFixture()
        let recorder = KeyExportRecorder(blocks: true)
        let model = fixture.model(recorder)
        let task = Task { await model.export(to: [fixture.alpha.id]) }
        await recorder.waitUntilStarted()
        #expect(model.isExporting && !model.isFinished)
        #expect(model.states[fixture.alpha.id] == .running)
        await model.export(to: [fixture.alpha.id, fixture.beta.id])
        #expect(model.selected == [fixture.alpha.id])
        #expect(await recorder.calls.count == 1)
        await recorder.resume()
        await task.value
        #expect(model.isFinished && !model.isExporting)
        #expect(model.states[fixture.alpha.id] == .succeeded)
        await model.export(to: [fixture.alpha.id])
        #expect(await recorder.calls.count == 1)
    }
}

@MainActor
struct KeyExportFixture {
    let key = SSHKeyRef(label: "Deployment Key", publicKey: "ssh-ed25519 fixture-public-key")
    let alpha: TermindDomain.Host
    let beta: TermindDomain.Host
    let untrusted: TermindDomain.Host
    let library: HostLibraryModel
    let credentials: CredentialLibraryModel

    init() {
        let identity = Identity(name: "Deployment", username: "deploy")
        alpha = TermindDomain.Host(name: "Alpha", host: "alpha.example.invalid", identityID: identity.id)
        beta = TermindDomain.Host(name: "Beta", host: "beta.example.invalid", identityID: identity.id)
        untrusted = TermindDomain.Host(name: "Untrusted", host: "untrusted.example.invalid", identityID: identity.id)
        var telnet = TermindDomain.Host(name: "Telnet", host: "telnet.example.invalid", identityID: identity.id)
        telnet.sshEnabled = false
        telnet.telnetEnabled = true
        library = HostLibraryModel(
            hosts: [alpha, beta, untrusted, telnet], identities: [identity],
            knownHosts: [alpha, beta].map { KnownHostEntry(hostname: $0.host, fingerprint: "SHA256:fixture") })
        credentials = CredentialLibraryModel(library: library)
    }

    func model(_ recorder: KeyExportRecorder) -> KeyExportModel {
        KeyExportModel(
            keys: [key], credentials: credentials, services: KeyExportServices(install: recorder.install))
    }
}

actor KeyExportRecorder {
    struct Call: Sendable {
        let hostID: UUID
        let publicKeys: [String]
        let names: [String]
        let username: String
        let trustedKeys: Set<SSHHostKeyIdentity>
    }

    private(set) var calls: [Call] = []
    private let failingHost: UUID?
    private let blocks: Bool
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    init(failingHost: UUID? = nil, blocks: Bool = false) {
        self.failingHost = failingHost
        self.blocks = blocks
    }

    func install(_ keys: [SSHAuthorizedKeyInstall], _ configuration: SSHConnectionConfiguration) async throws {
        calls.append(
            Call(
                hostID: configuration.hostID, publicKeys: keys.map(\.publicKey), names: keys.map(\.name),
                username: configuration.username, trustedKeys: configuration.expectedHostKeys))
        if blocks {
            await withCheckedContinuation { continuation in
                release = continuation
                started?.resume()
                started = nil
            }
        }
        if configuration.hostID == failingHost { throw ExportFailure() }
    }

    func waitUntilStarted() async {
        if !calls.isEmpty { return }
        await withCheckedContinuation { started = $0 }
    }

    func resume() {
        release?.resume()
        release = nil
    }

    private struct ExportFailure: LocalizedError {
        var errorDescription: String? { "Fixture export failure" }
    }
}
