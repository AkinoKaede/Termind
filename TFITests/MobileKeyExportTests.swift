import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileKeyExportTests {
    @Test func searchAndSelectAllOnlyChangeVisibleEligibleHosts() {
        let fixture = KeyExportFixture()
        let model = MobileMultiHostPickerModel(
            library: fixture.library, useCase: .keyExport, selected: [],
            isSelectable: { fixture.credentials.keyExportUnavailableReason(for: $0) == nil })
        #expect(model.hosts.count == 3)
        model.toggle(fixture.untrusted.id)
        #expect(model.selected.isEmpty)
        #expect(!model.isSelectable(fixture.untrusted))
        model.query = "Alpha"
        model.toggleAllResults()
        #expect(model.selected == [fixture.alpha.id])
        #expect(model.allResultsSelected)
        model.query = "Beta"
        model.toggleAllResults()
        #expect(model.selected == [fixture.alpha.id, fixture.beta.id])
        model.toggleAllResults()
        #expect(model.selected == [fixture.alpha.id])
        model.query = "no match"
        model.toggleAllResults()
        #expect(model.selected == [fixture.alpha.id])
        #expect(!model.allResultsSelected)
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
