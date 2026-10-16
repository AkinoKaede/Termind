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

    @Test(arguments: [HostTerminalProtocol.mosh, .eternalTerminal])
    func rendersRecoveryAndFailureInShortPanes(_ transport: HostTerminalProtocol) async throws {
        let host = TermindDomain.Host(name: "Production Gateway", host: "gateway.example.invalid")
        for language in ["en", "zh-Hans", "zh-Hant"] {
            for state in [ConnectionJourney.TransportRecovery.recovering, .suspended, .failed] {
                let journey = ConnectionJourney()
                journey.begin(host: host, route: [host], purpose: .terminal(transport), username: "deploy")
                journey.updateTransportRecovery(
                    state, message: String(localized: AppStrings.Transports.sessionUnavailable))
                let view = ConnectionJourneyView(
                    journey: journey, submitAuthentication: { _, _, _, _, _, _ in },
                    continueHostKey: { _ in }, trustHostKey: { _ in }, denyHostKey: {},
                    retry: { Issue.record("Recovery must not offer a new connection") }, cancel: {},
                    retryReconnectNow: {}
                )
                .environment(\.locale, Locale(identifier: language))
                .frame(width: 480, height: 440)
                let controller = NSHostingController(rootView: view)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
                    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentViewController = controller
                window.setContentSize(NSSize(width: 480, height: 440))
                window.makeKeyAndOrderFront(nil)
                defer {
                    window.orderOut(nil)
                    window.contentViewController = nil
                    window.close()
                }
                try await Task.sleep(for: .milliseconds(100))
                controller.view.layoutSubtreeIfNeeded()
                #expect(controller.view.bounds.height == 440)
                let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                Attachment.record(data, named: "\(transport.rawValue)-\(state)-\(language).png")
            }
        }
    }
}
