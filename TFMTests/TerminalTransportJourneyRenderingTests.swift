// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct TerminalTransportJourneyRenderingTests {
    @Test(arguments: [HostTerminalProtocol.mosh, .eternalTerminal])
    func recoveryHidesAndDefocusesTheMountedTerminal(_ transport: HostTerminalProtocol) async throws {
        let host = TermindDomain.Host(name: "Recovery", host: "test.invalid")
        let pane = Pane.sshSession(host: host, transport: transport)
        let session = try #require(pane.sshSession)
        let workspace = Workspace(pane: pane)
        let navigation = WindowModel(workspaces: [workspace])
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        session.receiveTransportState(.connected)
        let controller = NSHostingController(
            rootView: TerminalPlaceholderView(
                sshSession: session, workspace: workspace, isVisible: true, requestsFocus: true,
                externalFileDrop: nil, externalRemoteDrop: nil, closePane: {}
            )
            .environment(app).environment(navigation))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            session.disconnect()
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(250))
        let terminalController = session.terminalState.controller
        #expect(session.terminalState.isSurfaceVisible)
        #expect(session.terminalViewOwner.hasKeyboardFocusForTesting)
        session.receiveTransportState(.recovering)
        try await Task.sleep(for: .milliseconds(250))
        #expect(!session.terminalState.isSurfaceVisible)
        #expect(!session.terminalViewOwner.hasKeyboardFocusForTesting)
        session.receiveTransportState(.connected)
        try await Task.sleep(for: .milliseconds(900))
        #expect(session.terminalState.isSurfaceVisible)
        #expect(session.terminalState.controller === terminalController)
        #expect(session.terminalViewOwner.hasKeyboardFocusForTesting)
    }

}
