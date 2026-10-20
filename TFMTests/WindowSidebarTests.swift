// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

nonisolated private struct SidebarTestSerialConnection: SerialPortConnection {
    func write(_: Data) async throws {}
    func close() async {}
}

nonisolated private struct SidebarTestSerialService: SerialPortServing {
    func portUpdates() -> AsyncStream<[SerialPortDescriptor]> {
        AsyncStream { $0.finish() }
    }
    func open(
        _: SerialConnectionConfiguration,
        receive _: @escaping @Sendable (Data) -> Void,
        disconnected _: @escaping @Sendable (String) -> Void,
        progress _: @escaping @Sendable (SerialPortOpenStage) -> Void
    ) async throws -> any SerialPortConnection {
        SidebarTestSerialConnection()
    }
}

@Suite
@MainActor
struct WindowSidebarTests {
    @Test
    func legacySidebarMaterialStaysWithinTheWindow() {
        let view = NSVisualEffectView()

        LegacySidebarMaterialBackground.configure(view)

        #expect(view.material == .windowBackground)
        #expect(view.blendingMode == .withinWindow)
        #expect(view.state == .followsWindowActiveState)
    }

    @Test
    func allDestinationsExposeNavigatorAndThreeToolSidebars() {
        let window = WindowModel()
        let expected: [WindowSidebarState.Mode] = [.navigation, .assistant, .snippets, .history]

        #expect(window.availableSidebarModes == expected)
        window.selectVault()
        #expect(window.availableSidebarModes == expected)
        window.selectAssistant()
        #expect(window.availableSidebarModes == expected)
        window.openSettings()
        #expect(window.availableSidebarModes == expected)
    }

    @Test
    func sidebarModeAndVisibilityAreWindowScopedAndSurviveNavigation() {
        let first = WindowModel()
        let second = WindowModel()

        first.sidebarMode = .history
        first.showsSidebar = false
        first.selectAssistant()

        #expect(first.sidebarMode == .history)
        #expect(!first.showsSidebar)
        #expect(second.sidebarMode == .navigation)
        #expect(second.showsSidebar)
    }

    @Test
    func focusedSerialPaneDisablesHistoryAndFallsBackToSnippets() {
        let sshPane = Pane.sshSession(host: Host(name: "Server", host: "server.example"))
        let workspace = Workspace(pane: sshPane)
        let window = WindowModel(workspaces: [workspace])
        let serialPane = Pane.serialSession(
            configuration: SerialConnectionConfiguration(devicePath: "/dev/ttyUSB0"),
            service: SidebarTestSerialService()
        )

        window.sidebarMode = .history
        workspace.splitFocusedPane(axis: .horizontal, with: serialPane)

        #expect(window.sidebarMode == .snippets)
        #expect(window.availableSidebarModes == [.navigation, .assistant, .snippets])
        #expect(!window.isSidebarModeEnabled(.history))
        #expect(window.isSidebarModeEnabled(.navigation))
        #expect(window.isSidebarModeEnabled(.assistant))
        #expect(window.isSidebarModeEnabled(.snippets))

        window.sidebarMode = .history
        window.activateSidebarMode(.history)
        #expect(window.sidebarMode == .snippets)

        workspace.focus(sshPane.id)
        #expect(window.isSidebarModeEnabled(.history))
        #expect(window.sidebarMode == .snippets)
    }

    @Test
    func selectingSerialWorkspaceReconcilesHistoryImmediately() {
        let sshWorkspace = Workspace.sshSession(
            host: Host(name: "Server", host: "server.example")
        )
        let window = WindowModel(workspaces: [sshWorkspace])
        window.sidebarMode = .history

        let serialWorkspace = window.openSerialSession(
            configuration: SerialConnectionConfiguration(devicePath: "/dev/ttyUSB0"),
            service: SidebarTestSerialService()
        )

        #expect(window.selectedDestination == .workspace(serialWorkspace.id))
        #expect(window.sidebarMode == .snippets)
        #expect(!window.isSidebarModeEnabled(.history))

        window.select(sshWorkspace.id)
        #expect(window.isSidebarModeEnabled(.history))
        #expect(window.sidebarMode == .snippets)
    }

    @Test
    func statusBarBelongsOnlyToWorkPanes() {
        #expect(PaneKind.sshSession.showsStatusBar)
        #expect(PaneKind.sftpChannel.showsStatusBar)
        #expect(!PaneKind.empty.showsStatusBar)
    }
}
