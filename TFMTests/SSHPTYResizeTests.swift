// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CSSH2
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct SSHPTYResizeTests {
    @Test
    func viewportReceivedBeforeConnectOverridesTheInitialFallback() {
        var state = SSHPTYResizeState()
        let viewport = SSHPTYSize(columns: 132, rows: 43, widthPixels: 2112, heightPixels: 1376)
        state.request(viewport)
        _ = state.beginConnection(columns: 80, rows: 24)
        #expect(state.requestedSize == viewport)
    }

    @Test
    func authenticationKeepsTheLatestValidSizeForTheInitialPTY() {
        var state = SSHPTYResizeState()
        _ = state.beginConnection(columns: 80, rows: 24)
        state.request(SSHPTYSize(columns: 100, rows: 30))
        let latest = SSHPTYSize(columns: 132, rows: 43, widthPixels: 2112, heightPixels: 1376)
        state.request(latest)
        state.request(SSHPTYSize(columns: 0, rows: 43))
        state.request(SSHPTYSize(columns: 132, rows: 0))
        #expect(state.requestedSize == latest)
        #expect(
            state.flush { _ in
                Issue.record("Resize sent before PTY creation")
                return 0
            } == 0)
    }

    @Test
    func initialPTYAndUnchangedViewportsDoNotSendRedundantWindowChanges() {
        var state = connectedState()
        state.request(SSHPTYSize(columns: 80, rows: 24))
        #expect(
            state.flush { _ in
                Issue.record("Unchanged viewport sent")
                return 0
            } == 0)
    }

    @Test
    func updatesAreCoalescedWithoutDroppingPixelDimensions() {
        var state = connectedState()
        state.request(SSHPTYSize(columns: 100, rows: 30))
        let latest = SSHPTYSize(columns: 120, rows: 40, widthPixels: 1920, heightPixels: 1280)
        state.request(latest)
        var delivered: [SSHPTYSize] = []
        #expect(
            state.flush {
                delivered.append($0)
                return 0
            } == 0)
        #expect(delivered == [latest])

        let pixelsChanged = SSHPTYSize(columns: 120, rows: 40, widthPixels: 1921, heightPixels: 1281)
        state.request(pixelsChanged)
        #expect(
            state.flush {
                delivered.append($0)
                return 0
            } == 0)
        #expect(delivered == [latest, pixelsChanged])
    }

    @Test
    func blockedPacketCompletesBeforeSendingTheNewestViewport() {
        var state = connectedState()
        let blocked = SSHPTYSize(columns: 100, rows: 30, widthPixels: 1600, heightPixels: 960)
        let latest = SSHPTYSize(columns: 140, rows: 50, widthPixels: 2240, heightPixels: 1600)
        var attempts: [SSHPTYSize] = []
        state.request(blocked)
        #expect(
            state.flush {
                attempts.append($0)
                return LIBSSH2_ERROR_EAGAIN
            } == LIBSSH2_ERROR_EAGAIN)
        state.request(SSHPTYSize(columns: 120, rows: 40))
        state.request(latest)
        #expect(
            state.flush {
                attempts.append($0)
                return LIBSSH2_ERROR_EAGAIN
            } == LIBSSH2_ERROR_EAGAIN)
        #expect(
            state.flush {
                attempts.append($0)
                return 0
            } == 0)
        #expect(attempts == [blocked, blocked, blocked, latest])
        #expect(
            state.flush { _ in
                Issue.record("Completed resize sent again")
                return 0
            } == 0)
    }

    @Test
    func returningToAnEarlierSizeStillCompletesTheBlockedPacket() {
        var state = connectedState()
        let blocked = SSHPTYSize(columns: 100, rows: 30)
        state.request(blocked)
        #expect(state.flush { _ in LIBSSH2_ERROR_EAGAIN } == LIBSSH2_ERROR_EAGAIN)
        let initial = SSHPTYSize(columns: 80, rows: 24)
        state.request(initial)
        var attempts: [SSHPTYSize] = []
        #expect(
            state.flush {
                attempts.append($0)
                return 0
            } == 0)
        #expect(attempts == [blocked, initial])
    }

    @Test
    func aFailedResizeKeepsTheConnectionAndCanBeRequestedAgain() {
        var state = connectedState()
        let generation = state.generation
        let size = SSHPTYSize(columns: 100, rows: 30)
        state.request(size)
        var attempts = 0
        #expect(
            state.flush { _ in
                attempts += 1
                return LIBSSH2_ERROR_SOCKET_SEND
            } == LIBSSH2_ERROR_SOCKET_SEND)
        #expect(attempts == 1)
        state.discardFailedRequest()
        #expect(state.generation == generation)
        #expect(
            state.flush { _ in
                Issue.record("Failed resize retried without a new request")
                return 0
            } == 0)
        state.request(size)
        var delivered: [SSHPTYSize] = []
        #expect(
            state.flush {
                delivered.append($0)
                return 0
            } == 0)
        #expect(delivered == [size])
    }

    @Test
    func aFailedBlockedPacketDoesNotDiscardANewerViewport() {
        var state = connectedState()
        state.request(SSHPTYSize(columns: 100, rows: 30))
        #expect(state.flush { _ in LIBSSH2_ERROR_EAGAIN } == LIBSSH2_ERROR_EAGAIN)
        let latest = SSHPTYSize(columns: 120, rows: 40)
        state.request(latest)
        #expect(state.flush { _ in LIBSSH2_ERROR_SOCKET_SEND } == LIBSSH2_ERROR_SOCKET_SEND)
        state.discardFailedRequest()
        var delivered: [SSHPTYSize] = []
        #expect(
            state.flush {
                delivered.append($0)
                return 0
            } == 0)
        #expect(delivered == [latest])
    }

    @Test
    func disconnectDropsPendingPacketsAndIgnoresLateViewports() {
        var state = connectedState()
        let oldGeneration = state.generation
        state.request(SSHPTYSize(columns: 100, rows: 30))
        #expect(state.flush { _ in LIBSSH2_ERROR_EAGAIN } == LIBSSH2_ERROR_EAGAIN)
        state.reset()
        state.request(SSHPTYSize(columns: 120, rows: 40))
        #expect(state.requestedSize == nil)
        #expect(state.generation == nil)
        let generation = state.beginConnection(columns: 90, rows: 25)
        #expect(generation != oldGeneration)
        let initial = SSHPTYSize(columns: 90, rows: 25)
        #expect(state.requestedSize == initial)
        state.didCreatePTY(size: initial)
        #expect(
            state.flush { _ in
                Issue.record("Old connection's resize replayed")
                return 0
            } == 0)
    }

    @Test
    func replacingAnAttemptDiscardsItsViewportAndGeneration() {
        var state = SSHPTYResizeState()
        let oldGeneration = state.beginConnection(columns: 80, rows: 24)
        state.request(SSHPTYSize(columns: 120, rows: 40))
        let newGeneration = state.beginConnection(columns: 90, rows: 25)
        #expect(newGeneration != oldGeneration)
        #expect(state.requestedSize == SSHPTYSize(columns: 90, rows: 25))
    }

    private func connectedState() -> SSHPTYResizeState {
        var state = SSHPTYResizeState()
        _ = state.beginConnection(columns: 80, rows: 24)
        state.didCreatePTY(size: SSHPTYSize(columns: 80, rows: 24))
        return state
    }
}
