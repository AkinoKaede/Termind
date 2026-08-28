#if canImport(AppKit)
    import AppKit
    import SwiftUI
    import Testing

    @testable import Termind

    private nonisolated let hasActiveDisplay: Bool = {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return false }
        return count > 0
    }()

    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }
    }

    @MainActor
    private final class TextBox {
        var value = ""
    }

    /// Uses a real responder chain: the regression is specifically AppKit moving
    /// first responder while SwiftUI updates the pane being searched.
    @Suite
    @MainActor
    struct WindowToolbarFocusTests {
        private func makeField() -> (NSSearchField, NativeSearchField.Coordinator, NSWindow) {
            let box = TextBox()
            let representable = NativeSearchField(
                text: Binding(get: { box.value }, set: { box.value = $0 }),
                placeholder: "Search"
            )
            let coordinator = representable.makeCoordinator()
            let searchField = NSSearchField(
                frame: NSRect(x: 0, y: 0, width: 220, height: 24)
            )
            searchField.delegate = coordinator
            coordinator.attach(to: searchField)

            let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
            content.addSubview(searchField)
            let window = NSWindow(
                contentRect: content.frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = content
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return (searchField, coordinator, window)
        }

        @Test(.disabled(if: !hasActiveDisplay, "needs a window server"))
        func escapeGivesTheKeyboardUp() throws {
            let box = TextBox()
            var cancelled = false
            let representable = NativeSearchField(
                text: Binding(get: { box.value }, set: { box.value = $0 }),
                placeholder: "Search",
                cancel: { cancelled = true }
            )
            let coordinator = representable.makeCoordinator()
            let searchField = NSSearchField(
                frame: NSRect(x: 0, y: 0, width: 220, height: 24)
            )
            searchField.delegate = coordinator
            coordinator.attach(to: searchField)

            let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
            content.addSubview(searchField)
            let thief = FocusableView(frame: NSRect(x: 0, y: 40, width: 100, height: 20))
            content.addSubview(thief)
            let window = NSWindow(
                contentRect: content.frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = content
            window.makeKeyAndOrderFront(nil)

            coordinator.focusFromCommand(searchField)
            let editor = try #require(searchField.currentEditor() as? NSTextView)

            let handled = coordinator.control(
                searchField,
                textView: editor,
                doCommandBy: #selector(NSResponder.cancelOperation(_:))
            )
            #expect(handled)
            #expect(cancelled)

            #expect(window.makeFirstResponder(thief))
            #expect(window.firstResponder === thief)
        }

        @Test(.disabled(if: !hasActiveDisplay, "needs a window server"))
        func recreatedFieldInheritsTheExistingKeyboardClaim() async throws {
            let box = TextBox()
            let representable = NativeSearchField(
                text: Binding(get: { box.value }, set: { box.value = $0 }),
                placeholder: "Search",
                maintainsKeyboardFocus: true
            )
            let coordinator = representable.makeCoordinator()
            let searchField = NSSearchField(
                frame: NSRect(x: 0, y: 0, width: 220, height: 24)
            )
            searchField.stringValue = "abc"
            searchField.delegate = coordinator
            coordinator.attach(to: searchField)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView?.addSubview(searchField)
            window.makeKeyAndOrderFront(nil)

            coordinator.restoreKeyboardClaimIfNeeded(to: searchField)
            try await Task.sleep(for: .milliseconds(20))

            #expect(searchField.currentEditor() != nil)
        }

        @Test(.disabled(if: !hasActiveDisplay, "needs a window server"))
        func commandFocusWorksAgainAfterEscape() throws {
            let box = TextBox()
            let representable = NativeSearchField(
                text: Binding(get: { box.value }, set: { box.value = $0 }),
                placeholder: "Search",
                cancel: {}
            )
            let coordinator = representable.makeCoordinator()
            let searchField = NSSearchField(
                frame: NSRect(x: 0, y: 0, width: 220, height: 24)
            )
            searchField.delegate = coordinator
            coordinator.attach(to: searchField)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView?.addSubview(searchField)
            window.makeKeyAndOrderFront(nil)

            coordinator.focusFromCommand(searchField)
            let firstEditor = try #require(searchField.currentEditor() as? NSTextView)
            _ = coordinator.control(
                searchField,
                textView: firstEditor,
                doCommandBy: #selector(NSResponder.cancelOperation(_:))
            )

            coordinator.focusFromCommand(searchField)
            #expect(searchField.currentEditor() != nil)
        }

        @Test(.disabled(if: !hasActiveDisplay, "needs a window server"))
        func mouseClickGivesTheKeyboardUp() throws {
            let (searchField, coordinator, window) = makeField()
            let thief = FocusableView(frame: NSRect(x: 0, y: 40, width: 100, height: 20))
            window.contentView?.addSubview(thief)
            coordinator.focusFromCommand(searchField)
            #expect(searchField.currentEditor() != nil)

            let event = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: NSPoint(x: 20, y: 50),
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            )
            coordinator.handleUserEvent(event)
            #expect(window.makeFirstResponder(thief))

            #expect(window.firstResponder === thief)
        }

        @Test(.disabled(if: !hasActiveDisplay, "needs a window server"))
        func inactiveWindowDoesNotKeepTheKeyboardClaim() {
            let (searchField, coordinator, window) = makeField()
            let thief = FocusableView(frame: NSRect(x: 0, y: 40, width: 100, height: 20))
            window.contentView?.addSubview(thief)
            coordinator.focusFromCommand(searchField)

            let otherWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            otherWindow.makeKeyAndOrderFront(nil)
            #expect(!window.isKeyWindow)

            #expect(window.makeFirstResponder(thief))
            #expect(window.firstResponder === thief)
        }

        @Test(.disabled(if: !hasActiveDisplay, "needs a window server"))
        func remountingAFocusedTerminalDoesNotReassertFirstResponder() throws {
            let (searchField, coordinator, window) = makeField()
            let sshSession = SSHSessionModel(hostID: UUID(), title: "web-01")
            let mount = TerminalMountView(
                frame: NSRect(x: 0, y: 40, width: 320, height: 160)
            )
            window.contentView?.addSubview(mount)

            sshSession.terminalViewOwner.mount(
                in: mount,
                state: sshSession.terminalState,
                isVisible: true,
                requestsFocus: true
            )

            coordinator.focusFromCommand(searchField)
            let editor = try #require(searchField.currentEditor())

            for _ in 0..<5 {
                sshSession.terminalViewOwner.mount(
                    in: mount,
                    state: sshSession.terminalState,
                    isVisible: true,
                    requestsFocus: true
                )
            }

            #expect(window.firstResponder === editor)
            #expect(!sshSession.terminalViewOwner.hasKeyboardFocusForTesting)
        }
    }
#endif
