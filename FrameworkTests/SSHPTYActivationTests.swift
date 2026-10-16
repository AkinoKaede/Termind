import CSSH2
import Foundation
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct SSHPTYActivationTests {
    @Test func activationWaitsForDetectionAndOnlyClaimsEachClientOnce() throws {
        var state = SSHPTYActivationState()
        state.setActive(true)
        #expect(state.takeRequest(resizeIsSynchronized: true) == nil)
        let client = try identity()
        state.updateClient(client)
        let request = try takeRequest(&state)
        #expect(state.isCurrent(request))
        state.finish(request)
        state.updateClient(client)
        state.setActive(true)
        #expect(state.takeRequest(resizeIsSynchronized: true) == nil)
        state.setActive(false)
        state.setActive(true)
        let next = try takeRequest(&state)
        #expect(next != request)
        #expect(!state.isCurrent(request))
    }

    @Test func viewportChangesWaitForTheLastBlockedResizeBeforeActivation() throws {
        var resize = SSHPTYResizeState()
        var state = SSHPTYActivationState()
        state.updateClient(try identity())
        state.setActive(true)
        #expect(!resize.isSynchronized)
        _ = resize.beginConnection(columns: 80, rows: 24)
        resize.didCreatePTY(size: SSHPTYSize(columns: 80, rows: 24))
        resize.request(SSHPTYSize(columns: 100, rows: 30))
        #expect(resize.flush { _ in LIBSSH2_ERROR_EAGAIN } == LIBSSH2_ERROR_EAGAIN)
        #expect(state.takeRequest(resizeIsSynchronized: resize.isSynchronized) == nil)
        resize.request(SSHPTYSize(columns: 120, rows: 40))
        state.viewportChanged()
        var delivered: [SSHPTYSize] = []
        #expect(
            resize.flush {
                delivered.append($0)
                return 0
            } == 0)
        #expect(delivered == [SSHPTYSize(columns: 100, rows: 30), SSHPTYSize(columns: 120, rows: 40)])
        let request = try takeRequest(&state, synchronized: resize.isSynchronized)
        state.viewportChanged()
        #expect(!state.isCurrent(request))
        let latest = try takeRequest(&state, synchronized: resize.isSynchronized)
        state.finish(request)
        #expect(state.isCurrent(latest))
        state.finish(latest)
        // Ordinary live resizing already sends SIGWINCH; do not add an exec for every grid change.
        state.viewportChanged()
        #expect(state.takeRequest(resizeIsSynchronized: true) == nil)
    }

    @Test func failedResizeCannotActivateUsingAnUnappliedViewport() throws {
        var resize = SSHPTYResizeState()
        _ = resize.beginConnection(columns: 80, rows: 24)
        resize.didCreatePTY(size: SSHPTYSize(columns: 80, rows: 24))
        resize.request(SSHPTYSize(columns: 120, rows: 40))
        _ = resize.flush { _ in LIBSSH2_ERROR_SOCKET_SEND }
        resize.discardFailedRequest()
        var state = SSHPTYActivationState()
        state.setActive(true)
        state.updateClient(try identity())
        #expect(state.takeRequest(resizeIsSynchronized: resize.isSynchronized) == nil)
        resize.request(SSHPTYSize(columns: 120, rows: 40))
        _ = resize.flush { _ in 0 }
        #expect(state.takeRequest(resizeIsSynchronized: resize.isSynchronized) != nil)
    }

    @Test func blurInputDetachAndConnectionReplacementInvalidateOldRequests() throws {
        for reason in ["blur", "input", "detach", "reset"] {
            var state = SSHPTYActivationState()
            state.setActive(true)
            state.updateClient(try identity())
            let request = try takeRequest(&state)
            switch reason {
            case "blur": state.setActive(false)
            case "input": state.noteInput()
            case "detach": state.updateClient(nil)
            default: state.reset()
            }
            #expect(!state.isCurrent(request))
            #expect(state.takeRequest(resizeIsSynchronized: true) == nil)
            state.finish(request)
            state.reset()
            state.setActive(true)
            state.updateClient(try identity())
            let next = try takeRequest(&state)
            #expect(!state.isCurrent(request))
            #expect(state.isCurrent(next))
        }
    }

    @Test func aNewClientCanBeActivatedWithoutAnotherLocalFocusTransition() throws {
        var state = SSHPTYActivationState()
        state.setActive(true)
        state.updateClient(try identity())
        let old = try takeRequest(&state)
        state.updateClient(try identity(process: "556"))
        let next = try takeRequest(&state)
        #expect(!state.isCurrent(old))
        state.finish(old)
        #expect(state.isCurrent(next))
        state.updateClient(nil)
        state.updateClient(try identity())
        #expect(state.takeRequest(resizeIsSynchronized: true) != nil)
    }

    @Test func signalIdentityRejectsGroupsServerPIDsAndMalformedFields() throws {
        for process in ["0", "-1", "-555", "+555", "2147483648", "777", "0777", "555;echo bad"] {
            #expect(RemoteTmuxClientIdentity(update: update(process: process), terminal: "/dev/pts/1") == nil)
        }
        var value = update()
        value.status = .ordinary
        #expect(RemoteTmuxClientIdentity(update: value, terminal: "/dev/pts/1") == nil)
        #expect(RemoteTmuxClientIdentity(update: update(), terminal: "/dev/pts/2") == nil)
        value = update()
        value.clientIdentity = "/dev/pts/1:555:100:extra"
        #expect(RemoteTmuxClientIdentity(update: value, terminal: "/dev/pts/1") == nil)
        value = update()
        value.active = .init(backend: "tmux", server: "777", session: "$0;bad:99", pane: "%1", shellInstance: "")
        #expect(RemoteTmuxClientIdentity(update: value, terminal: "/dev/pts/1") == nil)
        #expect(try identity().process == "555")
    }

    private func takeRequest(
        _ state: inout SSHPTYActivationState, synchronized: Bool = true
    ) throws -> SSHPTYActivationState.Request {
        let request = state.takeRequest(resizeIsSynchronized: synchronized)
        return try #require(request)
    }

    private func identity(process: String = "555") throws -> RemoteTmuxClientIdentity {
        try #require(RemoteTmuxClientIdentity(update: update(process: process), terminal: "/dev/pts/1"))
    }

    private func update(process: String = "555") -> TerminalRuntimeUpdate {
        .init(
            status: .multiplexer, clientIdentity: "/dev/pts/1:\(process):100",
            active: .init(backend: "tmux", server: "777", session: "$0:99", pane: "%1", shellInstance: "unintegrated"))
    }
}
