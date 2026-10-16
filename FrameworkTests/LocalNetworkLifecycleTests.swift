import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct LocalNetworkLifecycleTests {
    @Test(arguments: [LocalDiscoveryProtocol.ssh, .telnet])
    func rescanningAndDismissalRejectLateDiscoveryResults(_ connectionProtocol: LocalDiscoveryProtocol) async throws {
        let service = SuspendedDiscovery(connectionProtocol: connectionProtocol)
        let model = LocalDiscoveryModel(service: service)
        #expect(model.connectionProtocol == connectionProtocol)
        model.scan()
        await wait { service.requests.count == 1 }
        #expect(service.requests.count == 1)
        model.scan()
        await wait { service.requests.count == 2 }
        let current = DiscoveredLocalHost(
            name: "Current", address: "192.168.1.5", port: connectionProtocol.port, source: .probe,
            connectionProtocol: connectionProtocol)
        let stale = DiscoveredLocalHost(
            name: "Stale", address: "192.168.1.4", port: connectionProtocol.port, source: .probe,
            connectionProtocol: connectionProtocol)
        guard service.requests.count == 2 else {
            service.finishAll()
            return
        }
        service.requests[1].resume(returning: [current])
        await wait { model.phase == .finished }
        service.requests[0].resume(returning: [stale])
        await Task.yield()
        #expect(model.hosts == [current])
        model.scan()
        await wait { service.requests.count == 3 }
        model.cancel()
        if service.requests.count == 3 { service.requests[2].resume(returning: [stale]) }
        await Task.yield()
        #expect(model.hosts.isEmpty)
        #expect(model.phase == .idle)
    }

    @Test func discoveryDistinguishesDeniedUnavailableFailureAndEmpty() async {
        for (error, phase) in [
            (LocalDiscoveryError.permissionDenied, LocalDiscoveryModel.Phase.permissionDenied),
            (.unavailable, .unavailable), (.failed, .failed),
        ] {
            let model = LocalDiscoveryModel(service: FailingDiscovery(error: error))
            model.scan()
            await wait { model.phase != .scanning }
            #expect(model.phase == phase)
            #expect(model.hosts.isEmpty)
        }
    }

    @Test func macLookupUsesDraftCredentialsWithoutSavingOrAutoWaking() async throws {
        let host = Host(name: "Unsaved", host: "draft.invalid")
        let library = HostLibraryModel()
        let resolver = RecordingMACResolver()
        let model = HostMACAddressModel(
            host: host, library: library, resolver: resolver,
            submissions: [host.id: .init(username: "draft-user", password: "ephemeral")])
        model.start()
        await wait { model.isFinished }
        #expect(model.isFinished)
        #expect(library.hosts.isEmpty)
        #expect(library.identities.isEmpty)
        #expect(await resolver.receivedUsername == "draft-user")
        #expect(await resolver.receivedHost == "draft.invalid")
        #expect(await resolver.receivedWakeAction == false)
        #expect(model.candidates.first?.address.rawValue == "02:11:22:33:44:55")
        model.cancel()
    }

    @Test func physicalSSHAndTelnetOpenInvokeWakeBeforeNetworkAndRespectCancellation() async {
        let counter = WakeCounter()
        let before: ConnectionWakeAction = {
            await counter.increment()
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let ssh = Task {
            var config = SSHConnectionConfiguration(
                hostID: UUID(), host: "never-dial.invalid", port: 22, username: "user", credentials: [],
                expectedHostKeys: [])
            config.beforeConnect = before
            do {
                try await SSHConnection().connect(using: config)
                Issue.record("A cancelled physical connection must not open")
            } catch {
                #expect(error is CancellationError)
            }
        }
        await ssh.value
        #expect(await counter.count == 1)
        let telnet = Task {
            var config = TelnetConnectionConfiguration(hostID: UUID(), host: "never-dial.invalid", port: 23)
            config.beforeConnect = before
            do {
                try await TelnetConnection(output: { _ in }).connect(using: config)
                Issue.record("A cancelled physical connection must not open")
            } catch {
                #expect(error is CancellationError)
            }
        }
        await telnet.value
        #expect(await counter.count == 2)
        for transport in [HostTerminalProtocol.mosh, .eternalTerminal] {
            let task = Task {
                var config = SSHConnectionConfiguration(
                    hostID: UUID(), host: "never-dial.invalid", port: 22, username: "user", credentials: [],
                    expectedHostKeys: [])
                config.beforeConnect = before
                var options = HostTerminalTransports()
                options.moshEnabled = true
                options.eternalTerminalEnabled = true
                let client = ResumableTerminalClient(
                    transport: transport, output: { _ in }, stateChanged: { _ in }, shellIntegration: { _ in })
                do {
                    try await client.connect(
                        request: .init(configuration: config), options: options,
                        environment: [], shellIntegrationEnabled: false, columns: 80, rows: 24,
                        route: { throw CancellationError() }, progress: nil)
                    Issue.record("A cancelled physical connection must not open")
                } catch {
                    #expect(error is CancellationError)
                }
                await client.close()
            }
            await task.value
        }
        #expect(await counter.count == 4)
    }

    private func wait(until predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

@MainActor
private final class SuspendedDiscovery: LocalHostDiscovering {
    let connectionProtocol: LocalDiscoveryProtocol
    var requests: [CheckedContinuation<[DiscoveredLocalHost], any Error>] = []
    init(connectionProtocol: LocalDiscoveryProtocol = .ssh) { self.connectionProtocol = connectionProtocol }
    func discover() async throws -> [DiscoveredLocalHost] {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }
    func finishAll() { for request in requests { request.resume(returning: []) } }
}

@MainActor
private final class FailingDiscovery: LocalHostDiscovering {
    let connectionProtocol = LocalDiscoveryProtocol.ssh
    let error: LocalDiscoveryError
    init(error: LocalDiscoveryError) { self.error = error }
    func discover() async throws -> [DiscoveredLocalHost] { throw error }
}

private actor RecordingMACResolver: HostMACAddressResolving {
    var receivedUsername: String?
    var receivedHost: String?
    var receivedWakeAction = false
    func resolve(_ request: SSHConnectionRequest, progress: SSHRouteProgressHandler?) async throws
        -> [HostMACAddressCandidate]
    {
        receivedUsername = request.configuration.username
        receivedHost = request.configuration.host
        receivedWakeAction = request.configuration.beforeConnect != nil
        return [.init(interface: "en0", address: MACAddress("02:11:22:33:44:55")!)]
    }
}

private actor WakeCounter {
    var count = 0
    func increment() { count += 1 }
}
