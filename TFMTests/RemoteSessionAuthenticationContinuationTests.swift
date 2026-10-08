import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct RemoteSessionAuthenticationContinuationTests {
    @Test(arguments: [false, true], [false, true])
    func identityPolicyRunsAfterStagingAndConnectsOnlyAfterSuccessfulSave(save: Bool, failsSave: Bool) {
        let identity = Identity(name: "Deploy", username: " saved-user ")
        let host = Host(name: "Server", host: "server.invalid")
        let store = HostLibraryModel(hosts: [host], identities: [identity])
        let controller = RemoteSessionConnectionController()
        controller.pendingAuthentication = SSHAuthenticationPrompt(host: host, username: "")
        controller.journey.begin(host: host, route: [host], purpose: .sshSession, username: nil)
        controller.journey.waitForLocalIdentity(at: host.id)
        var events: [String] = []

        controller.continueAuthentication(
            identityID: identity.id, username: "ignored", password: "one-use", passphrase: nil,
            keyID: nil, save: save, destinationID: host.id, using: store
        ) { stagedHost, submission in
            #expect(stagedHost.id == host.id)
            #expect(submission.username == "saved-user")
            #expect(controller.suppliedAuthentications[host.id]?.password == "one-use")
            #expect(controller.pendingAuthentication != nil)
            events.append("stage")
        } saveIdentity: { _, _, selected in
            #expect(selected?.id == identity.id)
            #expect(controller.pendingAuthentication == nil)
            #expect(controller.journey.phase == .connecting)
            events.append("save")
            if failsSave { throw TermindSSHError.missingCredential }
        } onFailure: { failure in
            guard case .identity(let failedHost, let username, _, let saving, _) = failure else {
                Issue.record("Expected an identity save failure")
                return
            }
            #expect(failedHost.id == host.id)
            #expect(username == "saved-user")
            #expect(saving)
            events.append("failure")
        } connect: {
            #expect(controller.pendingAuthentication == nil)
            events.append("connect")
        }

        #expect(events == (save ? ["stage", "save", failsSave ? "failure" : "connect"] : ["stage", "connect"]))
        controller.disconnect()
        #expect(controller.suppliedAuthentications.isEmpty)
    }

    @Test(arguments: [false, true])
    func proxyUsesEnteredUsernameAndSavesBeforeContinuing(_ save: Bool) throws {
        let identity = Identity(name: "Proxy", username: "identity-user")
        let host = Host(name: "Server", host: "server.invalid", proxy: HostProxy(hostname: "proxy.invalid"))
        let store = HostLibraryModel(hosts: [host], identities: [identity], secrets: InMemorySecretStore())
        let controller = RemoteSessionConnectionController()
        controller.pendingAuthentication = SSHAuthenticationPrompt(
            host: host, username: "", target: .proxy(ownerHostID: host.id))
        var connected = false
        controller.continueAuthentication(
            identityID: identity.id, username: " proxy-user ", password: "proxy-password", passphrase: nil,
            keyID: nil, save: save, destinationID: host.id, using: store,
            stageIdentity: { _, _ in Issue.record("Proxy must not stage SSH credentials") },
            saveIdentity: { _, _, _ in Issue.record("Proxy must not use the SSH save policy") },
            onFailure: { _ in Issue.record("Unexpected proxy failure") },
            connect: {
                connected = true
                #expect(controller.pendingAuthentication == nil)
                #expect(controller.suppliedAuthentications.isEmpty)
                #expect(controller.suppliedProxyAuthentications[host.id]?.username == "proxy-user")
                #expect(store.host(host.id)?.proxy?.identityID == (save ? identity.id : nil))
            })
        #expect(connected)
        let updatedIdentity = try #require(store.identity(identity.id))
        #expect(try store.passwordCredential(for: updatedIdentity) == (save ? "proxy-password" : nil))
        controller.disconnect()
        #expect(controller.suppliedProxyAuthentications.isEmpty)
    }

    @Test func proxySaveFailureDoesNotStageOrConnect() {
        let identity = Identity(name: "Missing", username: "identity-user", credentialRef: "missing")
        let host = Host(name: "Server", host: "server.invalid", proxy: HostProxy(hostname: "proxy.invalid"))
        let store = HostLibraryModel(hosts: [host], identities: [identity], secrets: InMemorySecretStore())
        let controller = RemoteSessionConnectionController()
        let prompt = SSHAuthenticationPrompt(host: host, username: "", target: .proxy(ownerHostID: host.id))
        controller.pendingAuthentication = prompt
        var failed = false
        controller.continueAuthentication(
            identityID: identity.id, username: "proxy-user", password: "replacement", passphrase: nil,
            keyID: nil, save: true, destinationID: host.id, using: store,
            stageIdentity: { _, _ in Issue.record("Unexpected SSH staging") },
            saveIdentity: { _, _, _ in Issue.record("Unexpected SSH save") },
            onFailure: { failure in
                guard case .proxy(let failedHost, _) = failure else {
                    Issue.record("Expected a proxy failure")
                    return
                }
                #expect(failedHost.id == host.id)
                failed = true
            },
            connect: { Issue.record("A failed save must not connect") })
        #expect(failed)
        #expect(controller.pendingAuthentication?.id == prompt.id)
        #expect(controller.suppliedProxyAuthentications.isEmpty)
        #expect(store.host(host.id) == host)
    }
}
