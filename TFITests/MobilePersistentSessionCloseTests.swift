import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobilePersistentSessionCloseTests {
    @Test(arguments: ["single", "others", "all"], [false, true])
    func closeRemovesLocalWorkBeforeCleanupAndNeverRemovesLaterWork(action: String, unopened: Bool) async throws {
        var dependencies = MobileAppDependencies.testing()
        var attempts = 0
        dependencies.persistentSessionTerminator = RemoteSessionTerminator { _ in
            attempts += 1
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
        let app = try MobileAppModel(dependencies: dependencies)
        let identity = Identity(name: "User", username: "user")
        app.library.upsert(identity)
        let host = Host(name: "Host", host: "example.invalid", identityID: identity.id)
        app.library.upsert(host)
        let transports: [HostTerminalProtocol] = [.ssh, .mosh, .eternalTerminal]
        let descriptors = (0..<3).map { index in
            MobileWorkspaceDescriptor(
                hostID: host.id, title: "Shell \(index)", kind: .terminal(transports[index]),
                remoteSession: .init(
                    backend: .tmux, session: .init(id: "\(index)", name: "Shell", identity: Data([UInt8(index)])),
                    hostID: host.id, endpoint: "example.invalid:22", username: "user", ownershipToken: UUID()))
        }
        let session = MobileWorkspaceSessionModel(
            id: "background-close", app: app, descriptors: unopened ? descriptors : [])
        if !unopened { session.restoreClosedStates(descriptors.map { .init(descriptor: $0) }) }
        defer {
            app.persistentSessionCloser.cancelAll()
            session.closeAll(authorized: true)
        }
        let remaining: Int
        switch action {
        case "single":
            session.close(descriptors[0].id)
            remaining = 2
        case "others":
            session.closeOtherWorkspaces(than: descriptors[0].id)
            remaining = 1
        default:
            session.closeAll()
            remaining = 0
        }
        #expect(session.orderedWorkspaceItems.count == remaining)
        #expect(attempts == 0)
        #expect(app.persistentSessionCloser.isClosing)
        #expect(app.closedWorkspaceRecords.flatMap(\.items).allSatisfy { $0.remoteSession == nil })

        let added = MobileWorkspaceDescriptor(hostID: host.id, title: "New work", kind: .ssh)
        session.restoreClosedStates([.init(descriptor: added)])
        for _ in 0..<200 {
            if attempts == 3 - remaining { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(attempts == 3 - remaining)
        app.persistentSessionCloser.cancelAll()
        await app.persistentSessionCloser.waitUntilIdle()
        #expect(session.orderedWorkspaceItems.count == remaining + 1)
        #expect(session.workspaces.contains { $0.id == added.id })
    }
}
