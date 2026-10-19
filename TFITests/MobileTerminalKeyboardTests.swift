import Foundation
import GhosttyTerminal
import SwiftUI
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized, .requiresKeyWindow)
@MainActor
struct MobileTerminalKeyboardIntegrationTests {
    @Test func initialFocusWaitsForReadinessAndReopensOnlyAfterRemount() async throws {
        let app = try MobileAppModel(inMemory: true)
        let workspace = MobileWorkspace(
            descriptor: .init(hostID: UUID(), title: "Initial Focus", kind: .ssh), hosts: app.library)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        defer {
            workspace.terminal.attachedPlatformView?.resignFirstResponder()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            workspace.disconnect()
        }

        func content(isReady: Bool) -> some View {
            TerminalSurfaceView(context: workspace.terminal)
                .modifier(MobileTerminalInitialFocus(terminal: workspace.terminal, isReady: isReady))
        }
        let host = UIHostingController(rootView: content(isReady: false))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(600))
        let terminal = try #require(workspace.terminal.attachedPlatformView)
        let waitsForReadiness = !terminal.isFirstResponder
        #expect(waitsForReadiness)

        host.rootView = content(isReady: true)
        try await Task.sleep(for: .milliseconds(600))
        let initiallyFocused = terminal.isFirstResponder
        #expect(initiallyFocused)

        terminal.resignFirstResponder()
        try await Task.sleep(for: .milliseconds(600))
        host.rootView = content(isReady: true)
        try await Task.sleep(for: .milliseconds(600))
        let remainsHidden = !terminal.isFirstResponder
        #expect(remainsHidden)

        window.rootViewController = nil
        window.rootViewController = UIHostingController(rootView: content(isReady: true))
        try await Task.sleep(for: .milliseconds(600))
        let focusedAfterRemount = terminal.isFirstResponder
        #expect(focusedAfterRemount)
    }

}
