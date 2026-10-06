import AppKit
import SwiftUI
import Testing

@testable import Termind

@Suite(.requiresVisibleWindow, .serialized)
@MainActor
struct WorkspaceNumberShortcutTests {
    @Test func hiddenButtonsHandleEveryDigitInTheirWindow() async throws {
        let model = WindowModel(workspaces: (0..<10).map { _ in Workspace(pane: Pane(.empty)) })
        let native = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        native.contentView = NSHostingView(
            rootView: Color.clear.background { WorkspaceNumberShortcuts(window: model) })
        native.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { native.close() }
        for _ in 0..<100 where !native.isKeyWindow { try await Task.sleep(for: .milliseconds(10)) }
        native.contentView?.layoutSubtreeIfNeeded()

        let keyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (offset, code) in keyCodes.enumerated() {
            model.selectVault()
            let digit = String(offset + 1)
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: native.windowNumber,
                    context: nil, characters: digit, charactersIgnoringModifiers: digit,
                    isARepeat: false, keyCode: code))

            #expect(AppShortcutRegistry.shared.routesToApplication(event))
            #expect(native.performKeyEquivalent(with: event))
            #expect(model.selectedWorkspaceID == model.workspaces[offset == 8 ? 9 : offset].id)
        }
    }
}
