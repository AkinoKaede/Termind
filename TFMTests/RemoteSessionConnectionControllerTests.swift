import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite @MainActor
struct RemoteSessionConnectionControllerTests {
    @Test(arguments: [ConnectionPurpose.sshSession, .sftpChannel])
    func reconnectTearsDownBeforeJourneyAndRetriesWithTheStore(_ purpose: ConnectionPurpose) async {
        let jump = Host(name: "Jump", host: "jump.invalid")
        let host = Host(name: "Server", host: "server.invalid")
        let store = HostLibraryModel(hosts: [host])
        let controller = RemoteSessionConnectionController(
            reconnect: SessionReconnectController(sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }))
        let route = SSHConnectionRoute(hosts: [jump, host], usernames: [host.id: "route-user"])
        controller.connectionRoute = route
        controller.markConnected()
        var didTeardown = false
        var didRetry = false

        controller.scheduleReconnect(
            after: "offline", hostID: host.id, using: store, purpose: purpose,
            route: purpose == .sshSession ? route : nil
        ) {
            #expect(controller.journey.phase == .hidden)
            #expect(controller.reconnectState == nil)
            didTeardown = true
        } retry: { retryStore in
            #expect(didTeardown)
            #expect(retryStore === store)
            #expect(controller.journey.mode == .reconnection)
            didRetry = true
        }

        #expect(didTeardown)
        #expect(controller.reconnectState?.lastError == "offline")
        #expect(controller.journey.purpose == purpose)
        #expect(
            controller.journey.endpoints.compactMap(\.hostID)
                == (purpose == .sshSession ? [jump.id, host.id] : [host.id]))
        controller.reconnect.retryNow()
        for _ in 0..<100 where !didRetry { await Task.yield() }
        #expect(didRetry)
        controller.disconnect()
    }

    @Test func disconnectCancelsTheScheduledReconnect() async {
        let host = Host(name: "Server", host: "server.invalid")
        let store = HostLibraryModel(hosts: [host])
        let controller = RemoteSessionConnectionController(
            reconnect: SessionReconnectController(sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }))
        controller.markConnected()
        var didRetry = false
        controller.scheduleReconnect(
            after: "offline", hostID: host.id, using: store, purpose: .sftpChannel,
            teardown: {}, retry: { _ in didRetry = true })
        controller.disconnect()
        controller.reconnect.retryNow()
        for _ in 0..<100 { await Task.yield() }
        #expect(!didRetry)
        #expect(controller.reconnectState == nil)
        #expect(controller.journey.phase == .hidden)
    }

    @Test func hostResolutionPrefersRouteThenLibraryThenTemporaryDestination() {
        let destination = Host(name: "Library", host: "library.invalid")
        var routed = destination
        routed.host = "route.invalid"
        let temporary = Host(name: "Temporary", host: "temporary.invalid")
        let store = HostLibraryModel(hosts: [destination])
        let controller = RemoteSessionConnectionController()
        controller.transientHost = temporary
        controller.connectionRoute = SSHConnectionRoute(hosts: [routed])

        #expect(controller.connectionHost(destination.id, destinationID: temporary.id, using: store) == routed)
        controller.connectionRoute = nil
        #expect(controller.connectionHost(destination.id, destinationID: temporary.id, using: store) == destination)
        #expect(controller.connectionHost(temporary.id, destinationID: temporary.id, using: store) == temporary)
        #expect(controller.connectionHost(UUID(), destinationID: temporary.id, using: store) == nil)
    }

    @Test func progressIgnoresReplacedAndClearedAttempts() async {
        let host = Host(name: "Server", host: "server.invalid")
        let controller = RemoteSessionConnectionController()
        controller.journey.begin(host: host, route: [host], purpose: .sshSession, username: "deploy")
        let first = UUID()
        controller.connectionAttemptID = first
        let oldProgress = controller.progressHandler(attemptID: first)
        let current = UUID()
        controller.connectionAttemptID = current
        let progress = controller.progressHandler(attemptID: current)
        let initialCount = controller.journey.logs.count
        oldProgress(.initializing(host.id, "stale"))
        progress(.initializing(host.id, "current"))
        for _ in 0..<100 where controller.journey.logs.count == initialCount { await Task.yield() }
        #expect(controller.journey.logs.last?.message == "current")
        #expect(controller.journey.logs.count == initialCount + 1)

        controller.connectionAttemptID = nil
        progress(.initializing(host.id, "cleared"))
        for _ in 0..<100 { await Task.yield() }
        #expect(controller.journey.logs.count == initialCount + 1)
    }
}
