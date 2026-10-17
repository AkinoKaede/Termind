import Foundation
import GhosttyTerminal
import SwiftUI
import Testing
import UIKit

@testable import TermindIOS

@Suite @MainActor
struct MobileTerminalKeyboardTests {
    @Test func nativeAccessoryUsesUpstreamGroupsWithPasteLast() throws {
        let terminal = MobileTerminalView(frame: .zero)
        let items = terminal.inputAccessoryItems
        #expect(
            items == [
                .esc, .tab, .ctrl, .alt, .command, .divider,
                .arrowLeft, .arrowUp, .arrowDown, .arrowRight, .divider,
                .symbol("|"), .symbol("/"), .symbol("~"), .symbol("-"), .symbol("_"),
                .symbol("`"), .symbol("'"), .symbol("\""), .paste,
            ])
        let bar = try #require(terminal.inputAccessoryView)
        let buttons = accessoryButtons(in: bar)
        #expect(buttons.map(\.accessibilityLabel) == items.compactMap(\.title))
    }

    @Test func nativeAccessoryKeepsItsGeometryAndAllKeysReachable() throws {
        for width in [CGFloat(320), 390, 430, 844, 1024] {
            let terminal = MobileTerminalView(frame: .zero)
            let bar = try #require(terminal.inputAccessoryView)
            let expectedHeight: CGFloat = if #available(iOS 26, *) { 60 } else { 52 }
            #expect(bar.intrinsicContentSize.height == expectedHeight)
            bar.frame = CGRect(x: 0, y: 0, width: width, height: expectedHeight)
            bar.layoutIfNeeded()
            let scroll = try #require(descendants(bar).compactMap { $0 as? UIScrollView }.first)
            #expect(scroll.contentSize.width > 0)
            let buttons = accessoryButtons(in: bar)
            for button in buttons {
                #expect(button.bounds.size == CGSize(width: 36, height: 36))
            }
            let paste = try #require(buttons.last)
            scroll.setContentOffset(
                CGPoint(x: max(0, scroll.contentSize.width - scroll.bounds.width), y: 0), animated: false)
            #expect(scroll.bounds.contains(paste.convert(paste.bounds, to: scroll)))
        }
    }

}

/// Hosts the library's actual UIView for the existing opt-in rendering matrix.
struct MobileTerminalAccessoryPreview: UIViewRepresentable {
    var locksControl = false
    var scrollsToEnd = false

    func makeCoordinator() -> MobileTerminalView {
        let terminal = MobileTerminalView(frame: .zero)
        if locksControl {
            terminal.toggleStickyModifier(.ctrl)
            terminal.toggleStickyModifier(.ctrl)
        }
        return terminal
    }

    func makeUIView(context: Context) -> UIView {
        context.coordinator.inputAccessoryView!
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard scrollsToEnd else { return }
        DispatchQueue.main.async {
            uiView.layoutIfNeeded()
            if let scroll = descendants(uiView).compactMap({ $0 as? UIScrollView }).first {
                scroll.setContentOffset(
                    CGPoint(x: max(0, scroll.contentSize.width - scroll.bounds.width), y: 0), animated: false)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 390, height: uiView.intrinsicContentSize.height)
    }
}

@MainActor
private func accessoryButtons(in view: UIView) -> [UIButton] {
    descendants(view).compactMap { $0 as? UIButton }
}

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

    @Test func nativeButtonsSendKeysAndReservePasteFramingForClipboard() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        fixture.session.receive("\u{1B}[?2004h")
        fixture.session.waitForPendingOutput()
        for symbol in ["|", "/", "~", "-", "_", "`", "'", "\""] {
            fixture.output.clear()
            try fixture.button(title: symbol).sendActions(for: .touchUpInside)
            try await fixture.expectOutput(Data(symbol.utf8))
        }
        let oldClipboard = UIPasteboard.general.items
        defer { UIPasteboard.general.items = oldClipboard }
        UIPasteboard.general.string = "native paste"
        fixture.output.clear()
        try fixture.button(item: .paste).sendActions(for: .touchUpInside)
        try await fixture.expectOutput(Data("\u{1B}[200~native paste\u{1B}[201~".utf8))
    }

    @Test func stickyModifiersAreConsumedByNativeKeysAndDisabledDuringComposition() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        let control = try fixture.button(item: .ctrl)
        control.sendActions(for: .touchUpInside)
        fixture.terminal.sendKey(.c)
        try await fixture.expectOutput(Data([3]))
        #expect(fixture.terminal.stickyActivation(for: .ctrl) == .inactive)
        control.sendActions(for: .touchUpInside)
        control.sendActions(for: .touchUpInside)
        fixture.output.clear()
        fixture.terminal.sendKey(.c)
        try await fixture.expectOutput(Data([3]))
        #expect(fixture.terminal.stickyActivation(for: .ctrl) == .locked)
        fixture.terminal.resetStickyModifiers()
        fixture.terminal.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        #expect(!control.isEnabled)
        #expect(try !fixture.button(item: .alt).isEnabled)
        #expect(try !fixture.button(item: .command).isEnabled)
        fixture.terminal.unmarkText()
        #expect(control.isEnabled)
    }

    @Test func workspaceEnablesTheNativeAccessoryAndPreservesItsSurfaceAcrossKeyboardToggles() async throws {
        let fixture = try KeyboardFixture()
        defer { fixture.close() }
        try await fixture.ready()
        let surface = try #require(fixture.terminal.surface)
        fixture.terminal.toggleSoftwareKeyboard()
        try await Task.sleep(for: .milliseconds(600))
        let hidden = !fixture.terminal.isFirstResponder
        #expect(hidden)
        fixture.terminal.toggleSoftwareKeyboard()
        try await Task.sleep(for: .milliseconds(600))
        let focused = fixture.terminal.isFirstResponder
        #expect(focused)
        #expect(fixture.terminal.surface === surface)

        let app = try MobileAppModel(inMemory: true)
        let workspace = MobileWorkspace(
            descriptor: .init(hostID: UUID(), title: "Keyboard", kind: .ssh), hosts: app.library)
        defer { workspace.disconnect() }
        #expect(workspace.terminal.inputAccessoryItems == nil)
    }
}

@MainActor
private final class KeyboardFixture {
    let terminal = MobileTerminalSurface().view
    let output = KeyboardOutput()
    let session: InMemoryTerminalSession
    let controller = TerminalController(configSource: .none)
    let window: UIWindow
    let previous: UIWindow?

    init() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.keyWindow
        window = UIWindow(windowScene: scene)
        let output = output
        session = InMemoryTerminalSession(write: { output.append($0) }, resize: { _ in })
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        terminal.controller = controller
        let host = UIViewController()
        host.view = terminal
        window.rootViewController = host
        window.makeKeyAndVisible()
    }

    func ready() async throws {
        // Let the previous fixture's keyboard dismissal finish before opening ours.
        try await Task.sleep(for: .milliseconds(600))
        terminal.becomeFirstResponder()
        try await Task.sleep(for: .milliseconds(600))
        _ = try #require(terminal.surface)
        output.clear()
    }

    func button(item: TerminalInputAccessoryItem) throws -> UIButton {
        let bar = try #require(terminal.inputAccessoryView)
        return try #require(
            accessoryButtons(in: bar).first {
                $0.accessibilityLabel == item.title
            })
    }

    func button(title: String) throws -> UIButton {
        let bar = try #require(terminal.inputAccessoryView)
        return try #require(accessoryButtons(in: bar).first { $0.configuration?.title == title })
    }

    func expectOutput(_ expected: Data) async throws {
        for _ in 0..<100 {
            if output.data == expected { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Array(output.data) == Array(expected))
    }

    func close() {
        terminal.resignFirstResponder()
        window.isHidden = true
        window.rootViewController = nil
        terminal.controller = nil
        previous?.makeKey()
    }
}

private nonisolated final class KeyboardOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var data: Data { lock.withLock { storage } }
    func append(_ data: Data) { lock.withLock { storage.append(data) } }
    func clear() { lock.withLock { storage.removeAll() } }
}
