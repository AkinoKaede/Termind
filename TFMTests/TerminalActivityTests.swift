// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain
import Testing

@testable import Termind

@Suite
@MainActor
struct TerminalActivityTests {
    @Test func unmountedGhosttyFocusCannotActivateATerminal() async throws {
        let session = SSHSessionModel(host: Host(name: "Activity test", host: "test.invalid"))
        let state = session.terminalState
        #expect(!session.isTerminalActive)
        state.isSurfaceVisible = false
        state.terminalDidChangeFocus(true)
        try await settle()
        #expect(!session.isTerminalActive)
        state.isSurfaceVisible = true
        try await settle()
        #expect(!session.isTerminalActive)
        state.terminalDidChangeFocus(false)
        try await settle()
        #expect(!session.isTerminalActive)
        state.terminalDidChangeFocus(true)
        try await settle()
        #expect(!session.isTerminalActive)
        state.isSurfaceVisible = false
        try await settle()
        #expect(!session.isTerminalActive)
    }

    @Test func rapidVisibilityChangesDoNotReplayStaleActivation() async throws {
        let session = SSHSessionModel(host: Host(name: "Activity test", host: "test.invalid"))
        let state = session.terminalState
        state.terminalDidChangeFocus(true)
        try await settle()
        #expect(!session.isTerminalActive)
        for _ in 0..<10 {
            state.isSurfaceVisible = false
            state.isSurfaceVisible = true
        }
        state.isSurfaceVisible = false
        state.terminalDidChangeFocus(false)
        try await settle()
        #expect(!session.isTerminalActive)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(30))
    }
}
