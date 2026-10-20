// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CSSH2
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct SSHPTYStartupSizingTests {
    @Test func initialRequestUsesTheViewportAfterChannelAdmission() {
        var resize = SSHPTYResizeState()
        _ = resize.beginConnection(columns: 80, rows: 24)
        var startup = SSHPTYStartupSizing()
        let latest = SSHPTYSize(columns: 132, rows: 43, widthPixels: 2112, heightPixels: 1376)
        resize.request(latest)
        var requests: [SSHPTYSize] = []
        #expect(
            startup.requestPTY(resize: &resize) {
                requests.append($0)
                return 0
            } == 0)
        var starts = 0
        #expect(
            startup.startProcess(
                resize: &resize,
                sendResize: { _ in
                    Issue.record("The initial viewport was sent twice")
                    return 0
                },
                start: {
                    starts += 1
                    return 0
                }) == 0)
        #expect(requests == [latest])
        #expect(starts == 1)
        #expect(resize.isSynchronized)
    }

    @Test func aBlockedPTYRequestKeepsItsSizeThenFlushesTheLatestBeforeStarting() {
        var resize = SSHPTYResizeState()
        _ = resize.beginConnection(columns: 80, rows: 24)
        let initial = SSHPTYSize(columns: 80, rows: 24)
        let latest = SSHPTYSize(columns: 140, rows: 50, widthPixels: 2240, heightPixels: 1600)
        var startup = SSHPTYStartupSizing()
        var requests: [SSHPTYSize] = []
        #expect(
            startup.requestPTY(resize: &resize) {
                requests.append($0)
                return LIBSSH2_ERROR_EAGAIN
            } == LIBSSH2_ERROR_EAGAIN)
        resize.request(latest)
        #expect(
            startup.requestPTY(resize: &resize) {
                requests.append($0)
                return 0
            } == 0)
        var events: [String] = []
        var delivered: [SSHPTYSize] = []
        #expect(
            startup.startProcess(
                resize: &resize,
                sendResize: {
                    delivered.append($0)
                    events.append("resize")
                    return 0
                },
                start: {
                    events.append("start")
                    return 0
                }) == 0)
        #expect(requests == [initial, initial])
        #expect(delivered == [latest])
        #expect(events == ["resize", "start"])
        #expect(resize.isSynchronized)
    }

    @Test func windowChangeRetriesFinishBeforeTheProcessRequestBegins() {
        var resize = SSHPTYResizeState()
        _ = resize.beginConnection(columns: 80, rows: 24)
        var startup = SSHPTYStartupSizing()
        #expect(startup.requestPTY(resize: &resize) { _ in 0 } == 0)
        let blocked = SSHPTYSize(columns: 100, rows: 30)
        let latest = SSHPTYSize(columns: 140, rows: 50)
        resize.request(blocked)
        var attempts: [SSHPTYSize] = []
        var starts = 0
        #expect(
            startup.startProcess(
                resize: &resize,
                sendResize: {
                    attempts.append($0)
                    return LIBSSH2_ERROR_EAGAIN
                },
                start: {
                    starts += 1
                    return 0
                }) == LIBSSH2_ERROR_EAGAIN)
        #expect(starts == 0)
        resize.request(latest)
        #expect(
            startup.startProcess(
                resize: &resize,
                sendResize: {
                    attempts.append($0)
                    return 0
                },
                start: {
                    starts += 1
                    return 0
                }) == 0)
        #expect(attempts == [blocked, blocked, latest])
        #expect(starts == 1)
    }

    @Test func aBlockedProcessRequestIsNotInterruptedByAnotherWindowChange() {
        var resize = SSHPTYResizeState()
        _ = resize.beginConnection(columns: 80, rows: 24)
        var startup = SSHPTYStartupSizing()
        #expect(startup.requestPTY(resize: &resize) { _ in 0 } == 0)
        var starts = 0
        #expect(
            startup.startProcess(
                resize: &resize,
                sendResize: { _ in
                    Issue.record("Unchanged viewport sent")
                    return 0
                },
                start: {
                    starts += 1
                    return LIBSSH2_ERROR_EAGAIN
                }) == LIBSSH2_ERROR_EAGAIN)
        let latest = SSHPTYSize(columns: 120, rows: 40)
        resize.request(latest)
        #expect(
            startup.startProcess(
                resize: &resize,
                sendResize: { _ in
                    Issue.record("Interrupted a pending process request")
                    return 0
                },
                start: {
                    starts += 1
                    return 0
                }) == 0)
        var delivered: [SSHPTYSize] = []
        #expect(
            resize.flush {
                delivered.append($0)
                return 0
            } == 0)
        #expect(starts == 2)
        #expect(delivered == [latest])
    }

    @Test func aFailedWindowChangeDoesNotStartTheProcess() {
        var resize = SSHPTYResizeState()
        _ = resize.beginConnection(columns: 80, rows: 24)
        var startup = SSHPTYStartupSizing()
        #expect(startup.requestPTY(resize: &resize) { _ in 0 } == 0)
        resize.request(.init(columns: 120, rows: 40))
        #expect(
            startup.startProcess(
                resize: &resize,
                sendResize: { _ in LIBSSH2_ERROR_SOCKET_SEND },
                start: {
                    Issue.record("Started after a failed window change")
                    return 0
                }) == LIBSSH2_ERROR_SOCKET_SEND)
    }
}
