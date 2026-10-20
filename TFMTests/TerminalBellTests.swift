// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import GhosttyTerminal
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite @MainActor
struct TerminalBellTests {
    @Test func observationIgnoresHistoryCoalescesBurstsAndStopsOnRelease() async {
        let state = TerminalViewState(configSource: .none)
        state.terminalDidRingBell()
        #expect(await eventually { state.bellCount == 1 })
        var rings = 0
        var observation: TerminalBellObservation? = TerminalBellObservation(state: state) { rings += 1 }
        #expect(observation != nil)
        #expect(rings == 0)
        for _ in 0..<4 { state.terminalDidRingBell() }
        #expect(await eventually { state.bellCount == 5 })
        #expect(rings == 1)
        observation = nil
        state.terminalDidRingBell()
        #expect(await eventually { state.bellCount == 6 })
        #expect(rings == 1)
    }

    @Test func hiddenPanesUseLatestSettingsAndClosingStopsFeedback() async throws {
        var sounds = 0
        let host = Host(name: "Bell", host: "test.invalid")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]), terminalBellSound: { sounds += 1 })
        let window = WindowModel()
        app.registerWindow(window)
        let pane = Pane.sshSession(host: host)
        let workspace = Workspace(pane: pane)
        window.open(workspace, select: false)
        let state = try #require(pane.sshSession?.terminalState)
        state.terminalDidRingBell()
        #expect(await eventually { state.bellCount == 1 })
        #expect(sounds == 0)
        app.terminalExperienceSettings.set(true, for: \.bellSound)
        state.terminalDidRingBell()
        #expect(await eventually { state.bellCount == 2 })
        #expect(sounds == 1)
        app.terminalExperienceSettings.set(false, for: \.bellSound)
        state.terminalDidRingBell()
        #expect(await eventually { state.bellCount == 3 })
        #expect(sounds == 1)
        app.terminalExperienceSettings.set(true, for: \.bellSound)
        pane.disconnectConnection()
        state.terminalDidRingBell()
        #expect(await eventually { state.bellCount == 4 })
        #expect(sounds == 1)
    }

    @Test func reconfiguringPaneReplacesRatherThanDuplicatesItsListener() async throws {
        let pane = Pane.sshSession(host: Host(name: "Bell", host: "test.invalid"))
        defer { pane.disconnectConnection() }
        let state = try #require(pane.sshSession?.terminalState)
        var obsolete = 0
        var current = 0
        pane.configureTerminalBell { obsolete += 1 }
        pane.configureTerminalBell { current += 1 }
        state.terminalDidRingBell()
        #expect(await eventually { state.bellCount == 1 })
        #expect(obsolete == 0)
        #expect(current == 1)
    }

    @Test func windowsShareLivePreferencesAndMovingOrReopeningNeverReplaysBells() async throws {
        var sounds = 0
        let host = Host(name: "Bell", host: "test.invalid")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]), terminalBellSound: { sounds += 1 })
        let firstWindow = WindowModel()
        let secondWindow = WindowModel()
        app.registerWindow(firstWindow)
        app.registerWindow(secondWindow)
        let first = Pane.sshSession(host: host)
        let second = Pane.sshSession(host: host)
        let workspace = Workspace(pane: first)
        firstWindow.open(workspace, select: false)
        secondWindow.open(Workspace(pane: second), select: false)
        defer {
            first.disconnectConnection()
            second.disconnectConnection()
        }
        let firstState = try #require(first.sshSession?.terminalState)
        let secondState = try #require(second.sshSession?.terminalState)
        app.terminalExperienceSettings.set(true, for: \.bellSound)
        firstState.terminalDidRingBell()
        secondState.terminalDidRingBell()
        #expect(await eventually { firstState.bellCount == 1 && secondState.bellCount == 1 })
        #expect(sounds == 2)

        let moved = try #require(firstWindow.takeWorkspaceForMove(workspace.id))
        secondWindow.open(moved, select: false)
        #expect(sounds == 2)
        firstState.terminalDidRingBell()
        #expect(await eventually { firstState.bellCount == 2 })
        #expect(sounds == 3)
        app.terminalExperienceSettings.set(false, for: \.bellSound)
        firstState.terminalDidRingBell()
        secondState.terminalDidRingBell()
        #expect(await eventually { firstState.bellCount == 3 && secondState.bellCount == 2 })
        #expect(sounds == 3)

        let closed = try #require(secondWindow.takeWorkspaceForMove(workspace.id))
        closed.disconnectConnections()
        firstState.terminalDidRingBell()
        #expect(await eventually { firstState.bellCount == 4 })
        closed.prepareForReopen()
        app.terminalExperienceSettings.set(true, for: \.bellSound)
        firstWindow.open(closed, select: false)
        #expect(sounds == 3)
        let reopenedState = try #require(first.sshSession?.terminalState)
        reopenedState.terminalDidRingBell()
        #expect(await eventually { reopenedState.bellCount == 1 })
        #expect(sounds == 4)
    }

    private func eventually(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}
