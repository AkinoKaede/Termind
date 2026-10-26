// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import AppKit
import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite(.serialized) @MainActor
struct TerminalInputAreaLayoutTests {
    @Test(arguments: ["ssh", "telnet", "serial"])
    func connectionJourneyHidesTheInputAreaWithoutDiscardingItsDraft(transport: String) async throws {
        let suite = "TerminalInputAreaJourneyTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: DesktopSettingsKey.showTerminalInputArea)
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = Host(name: "journey", host: "journey.invalid")
        let pane: Pane
        let journey: ConnectionJourney
        switch transport {
        case "telnet":
            let session = TelnetSessionModel(host: host)
            session.status = .connected
            pane = Pane(.telnetSession(session))
            journey = session.connectionJourney
        case "serial":
            let session = SerialSessionModel(
                configuration: .init(devicePath: "/dev/termind-test"), service: InputAreaInertSerialService())
            session.status = .connected
            pane = Pane(.serialSession(session))
            journey = session.connectionJourney
        default:
            let session = SSHSessionModel(host: host)
            session.status = .connected
            pane = Pane(.sshSession(session))
            journey = session.connectionJourney
        }
        journey.begin(host: host, route: [host], purpose: .sshSession, username: nil)
        let workspace = Workspace(pane: pane)
        let app = AppModel(hosts: HostLibraryModel())
        let navigation = WindowModel(workspaces: [workspace])
        let controller = NSHostingController(
            rootView: WorkspaceContentView(workspace: workspace, isActive: true)
                .environment(app).environment(navigation).defaultAppStorage(defaults)
                .transaction { $0.disablesAnimations = true })
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 650, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(CGSize(width: 650, height: 480))
        defer {
            window.close()
            pane.disconnectConnection()
            app.shutdownForTermination()
        }
        func layout() async {
            controller.view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
            controller.view.layoutSubtreeIfNeeded()
        }
        func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
        }
        await layout()
        #expect(descendants(TerminalInputTextView.self, in: controller.view).isEmpty)
        journey.hide()
        await layout()
        let terminals = descendants(AppTerminalView.self, in: controller.view).map(ObjectIdentifier.init)
        #expect(terminals.count == 1)
        #expect(descendants(TerminalInputTextView.self, in: controller.view).count == 1)
        let input = pane.terminalInputArea
        input.draft = "keep this request"
        input.mode = .commandGenerator
        input.generate(
            context: .init(draft: input.draft, shell: "", cwd: ""),
            using: InputAreaPreviewGenerator(), isCurrent: { true })
        input.setEditorFocused(true, editorID: UUID())
        journey.begin(host: host, route: [host], purpose: .sshSession, username: nil)
        await layout()
        #expect(descendants(TerminalInputTextView.self, in: controller.view).isEmpty)
        #expect(!input.isGenerating && !input.isEditorFocused)
        journey.waitForAuthentication(at: host.id)
        await layout()
        #expect(descendants(TerminalInputTextView.self, in: controller.view).isEmpty)
        journey.waitForSessionSelection()
        await layout()
        #expect(descendants(TerminalInputTextView.self, in: controller.view).isEmpty)
        journey.fail("Connection failed")
        await layout()
        #expect(descendants(TerminalInputTextView.self, in: controller.view).isEmpty)
        journey.hide()
        await layout()
        #expect(descendants(TerminalInputTextView.self, in: controller.view).first?.string == "keep this request")
        #expect(input.mode == .commandGenerator)
        #expect(descendants(AppTerminalView.self, in: controller.view).map(ObjectIdentifier.init) == terminals)
        #expect(!window.isVisible)
    }

    @Test(arguments: [SplitAxis.horizontal, .vertical])
    func togglingAndResizingDoNotRecreateTheSplitTerminalSurfaces(axis: SplitAxis) async throws {
        let suite = "TerminalInputAreaWorkspaceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Pane.sshSession(host: Host(name: "one", host: "one.invalid"))
        let second = Pane.sshSession(host: Host(name: "two", host: "two.invalid"))
        let workspace = Workspace(pane: first)
        workspace.splitFocusedPane(axis: axis, with: second)
        for session in workspace.broadcastTargets {
            session.status = .connected
            session.connectionJourney.hide()
            session.inputSink = { _ in }
        }
        let app = AppModel(hosts: HostLibraryModel())
        let navigation = WindowModel(workspaces: [workspace])
        let controller = NSHostingController(
            rootView: WorkspaceContentView(workspace: workspace, isActive: true)
                .environment(app)
                .environment(navigation)
                .transaction { $0.disablesAnimations = true }
                .defaultAppStorage(defaults))
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(CGSize(width: 800, height: 600))
        defer {
            window.close()
            for pane in workspace.panes { pane.disconnectConnection() }
            app.shutdownForTermination()
        }
        func layout() async {
            controller.view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(350))
            controller.view.layoutSubtreeIfNeeded()
        }
        func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
        }
        await layout()
        let terminals = descendants(AppTerminalView.self, in: controller.view).map(ObjectIdentifier.init)
        let terminalHeights = descendants(AppTerminalView.self, in: controller.view).map(\.bounds.height)
        #expect(terminals.count == 2)
        #expect(descendants(TerminalInputTextView.self, in: controller.view).isEmpty)
        first.terminalInputArea.draft = "retained first draft"
        second.terminalInputArea.draft = "retained second draft"
        first.terminalInputArea.mode = .commandGenerator
        let preferredHeight = first.terminalInputArea.preferredHeight
        for visible in [true, false, true] {
            defaults.set(visible, forKey: DesktopSettingsKey.showTerminalInputArea)
            await layout()
            #expect(descendants(AppTerminalView.self, in: controller.view).map(ObjectIdentifier.init) == terminals)
            let editors = descendants(TerminalInputTextView.self, in: controller.view)
            let resizedHeights = descendants(AppTerminalView.self, in: controller.view).map(\.bounds.height)
            #expect(editors.count == (visible ? 2 : 0))
            if visible {
                #expect(Set(editors.map(\.string)) == ["retained first draft", "retained second draft"])
                #expect(zip(resizedHeights, terminalHeights).allSatisfy { $0 < $1 })
            } else {
                #expect(resizedHeights == terminalHeights)
            }
            #expect(first.terminalInputArea.mode == .commandGenerator)
            #expect(first.terminalInputArea.preferredHeight == preferredHeight)
        }
        for visible in [false, true, false, true, false] {
            defaults.set(visible, forKey: DesktopSettingsKey.showTerminalInputArea)
            try await Task.sleep(for: .milliseconds(30))
        }
        await layout()
        #expect(descendants(TerminalInputTextView.self, in: controller.view).isEmpty)
        defaults.set(true, forKey: DesktopSettingsKey.showTerminalInputArea)
        await layout()
        #expect(
            Set(descendants(TerminalInputTextView.self, in: controller.view).map(\.string))
                == ["retained first draft", "retained second draft"])
        window.setContentSize(CGSize(width: 400, height: 320))
        await layout()
        #expect(descendants(AppTerminalView.self, in: controller.view).map(ObjectIdentifier.init) == terminals)
        #expect(!window.isVisible)
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func resizingAndModeChangesPreserveTheNativeEditor(language: String) async throws {
        let fixture = InputAreaViewFixture(language: language)
        defer { fixture.close() }
        await fixture.layout()
        let editor = try #require(fixture.editor)
        let scroll = try #require(editor.enclosingScrollView)
        fixture.model.draft = String(repeating: "printf 'hello world'\n", count: 30)
        await fixture.layout()
        #expect(editor.string == fixture.model.draft)
        let selected = NSRange(location: 2, length: 5)
        editor.setSelectedRange(selected)
        for size in [
            CGSize(width: 160, height: 96),
            CGSize(width: 300, height: 96),
            CGSize(width: 650, height: 160),
            CGSize(width: 400, height: 240),
        ] {
            fixture.window.setContentSize(size)
            await fixture.layout()
            #expect(fixture.editor === editor)
            #expect(editor.selectedRange() == selected)
            #expect(scroll.bounds.width > 0 && scroll.bounds.height > 0)
            let frame = scroll.convert(scroll.bounds, to: fixture.controller.view)
            #expect(fixture.controller.view.bounds.contains(frame))
            #expect(scroll.hasVerticalScroller && scroll.autohidesScrollers)
            #expect(editor.bounds.height > scroll.contentSize.height)
        }
        fixture.model.mode = .commandGenerator
        await fixture.layout()
        #expect(fixture.editor === editor)
        #expect(editor.string == fixture.model.draft)
        #expect(!fixture.window.isVisible)
    }

    @Test
    func incidentalTerminalFocusRequestsPreserveTheEditorButExplicitRequestsCanReturnToTheTerminal() async throws {
        let fixture = InputAreaViewFixture()
        let session = SSHSessionModel(host: Host(name: "focus", host: "focus.invalid"))
        let mount = TerminalMountView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        let container = NSView(frame: fixture.controller.view.frame)
        fixture.window.contentView = container
        fixture.controller.view.frame = container.bounds
        fixture.controller.view.autoresizingMask = [.width, .height]
        container.addSubview(fixture.controller.view)
        container.addSubview(mount)
        defer {
            session.terminalViewOwner.unmount(from: mount)
            session.disconnect()
            fixture.close()
        }
        await fixture.layout()
        let editor = try #require(fixture.editor)
        #expect(fixture.window.makeFirstResponder(editor))
        session.terminalViewOwner.mount(
            in: mount, state: session.terminalState, isVisible: true, requestsFocus: true)
        session.terminalViewOwner.requestFocus(preservingTextEditor: true)
        await fixture.layout()
        #expect(fixture.window.firstResponder === editor)
        session.terminalViewOwner.requestFocus()
        #expect(session.terminalViewOwner.hasKeyboardFocusForTesting)
        #expect(!fixture.window.isVisible)
    }

    @Test
    func nativeEditorPreservesLiteralTextAndReturnInsertsANewline() async throws {
        let fixture = InputAreaViewFixture()
        defer { fixture.close() }
        await fixture.layout()
        let editor = try #require(fixture.editor)
        editor.insertText("echo \"literal\"", replacementRange: NSRange(location: 0, length: 0))
        editor.insertNewline(nil)
        editor.insertText("echo next", replacementRange: editor.selectedRange())
        #expect(fixture.model.draft == "echo \"literal\"\necho next")
        #expect(!editor.isRichText)
        #expect(!editor.isAutomaticQuoteSubstitutionEnabled)
        #expect(!editor.isAutomaticDashSubstitutionEnabled)
        #expect(!editor.isAutomaticTextReplacementEnabled)
        #expect(fixture.sent.isEmpty)
    }

    @Test(arguments: TerminalInputMode.allCases)
    func sidebarEditsReplaceTheSelectionAndPreserveNativeUndoAndMode(mode: TerminalInputMode) async throws {
        let fixture = InputAreaViewFixture()
        defer { fixture.close() }
        fixture.model.mode = mode
        await fixture.layout()
        let editor = try #require(fixture.editor)
        #expect(fixture.window.makeFirstResponder(editor))
        let undo = try #require(editor.undoManager)

        let cases: [(draft: String, selection: NSRange, inserted: String, expected: String)] = [
            ("", NSRange(location: 0, length: 0), "echo first\necho next", "echo first\necho next"),
            ("echo  tail", NSRange(location: 5, length: 0), "你好👋", "echo 你好👋 tail"),
            ("echo old tail", NSRange(location: 5, length: 3), "新值🌏\necho next", "echo 新值🌏\necho next tail"),
        ]
        for test in cases {
            fixture.model.draft = test.draft
            await fixture.layout()
            editor.setSelectedRange(test.selection)
            undo.removeAllActions()
            editor.insertSidebarText(test.inserted)
            await fixture.layout()

            #expect(fixture.model.draft == test.expected)
            #expect(editor.string == test.expected)
            #expect(
                editor.selectedRange()
                    == NSRange(
                        location: test.selection.location + (test.inserted as NSString).length, length: 0))
            #expect(fixture.model.mode == mode)
            #expect(fixture.window.firstResponder === editor)
            #expect(fixture.sent.isEmpty && fixture.generationRequests.isEmpty)
            #expect(undo.canUndo)
            undo.undo()
            await fixture.layout()
            #expect(editor.string == test.draft)
            #expect(fixture.model.draft == test.draft)
            #expect(undo.canRedo)
            undo.redo()
            await fixture.layout()
            #expect(fixture.model.draft == test.expected)
        }
        #expect(!fixture.window.isVisible)
    }

    @Test
    func sidebarInsertionReplacesNativeMarkedTextWithoutSubmittingIt() async throws {
        let fixture = InputAreaViewFixture()
        defer { fixture.close() }
        fixture.model.draft = "echo "
        await fixture.layout()
        let editor = try #require(fixture.editor)
        #expect(fixture.window.makeFirstResponder(editor))
        editor.setMarkedText(
            "ni", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: 5, length: 0))
        #expect(editor.hasMarkedText())
        editor.insertSidebarText("你好")
        await fixture.layout()
        #expect(!editor.hasMarkedText())
        #expect(editor.string == "echo 你好")
        #expect(fixture.model.draft == "echo 你好")
        #expect(fixture.sent.isEmpty)
        #expect(!fixture.window.isVisible)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERMIND_INPUT_AREA_SCREENSHOTS"] != nil))
    func exportLocalizedShortcutSettingsPreviews() async throws {
        for language in ["en", "zh-Hans"] {
            let fixture = InputAreaViewFixture(language: language)
            defer { fixture.close() }
            fixture.window.setContentSize(CGSize(width: 650, height: 240))
            fixture.controller.rootView = AnyView(
                Form {
                    Section(AppStrings.Settings.input.swiftUIKey) {
                        Toggle(AppStrings.TerminalInput.show.swiftUIKey, isOn: .constant(true))
                    }
                    Section(AppStrings.Settings.shortcuts.swiftUIKey) {
                        InputSendShortcutPicker()
                    }
                }
                .formStyle(.grouped)
                .environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, .light))
            await fixture.layout()
            try fixture.attachPreview("\(language)-shortcut-settings")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERMIND_INPUT_AREA_SCREENSHOTS"] != nil))
    func exportLocalizedInputAreaPreviews() async throws {
        for language in ["en", "zh-Hans"] {
            for mode in TerminalInputMode.allCases {
                let fixture = InputAreaViewFixture(language: language)
                defer { fixture.close() }
                fixture.model.mode = mode
                fixture.model.draft =
                    mode == .input
                    ? "find . -type f -name '*.swift'\n"
                    : (language == "en" ? "Find all Swift files in this directory" : "查找此目录下的所有 Swift 文件")
                for width in [650.0, 300, 160] {
                    fixture.window.setContentSize(CGSize(width: width, height: TerminalInputAreaModel.initialHeight))
                    await fixture.layout()
                    try fixture.attachPreview("\(language)-\(mode.rawValue)-\(Int(width))")
                }
            }
            let fixture = InputAreaViewFixture(language: language)
            defer { fixture.close() }
            await fixture.layout()
            try fixture.attachPreview("\(language)-empty")
            fixture.model.startTranscription(using: fixture.transcription)
            await fixture.layout()
            for level: Float in [0.2, 0.5, 0.8, 0.6, 0.4] { fixture.speechService.emit(.level(level)) }
            for width in [650.0, 300, 160] {
                fixture.window.setContentSize(CGSize(width: width, height: TerminalInputAreaModel.initialHeight))
                await fixture.layout()
                try fixture.attachPreview("\(language)-recording-\(Int(width))")
            }
            fixture.model.stopTranscription()
            for width in [650.0, 300, 160] {
                fixture.window.setContentSize(CGSize(width: width, height: TerminalInputAreaModel.initialHeight))
                await fixture.layout()
                try fixture.attachPreview("\(language)-transcribing-\(Int(width))")
            }
            fixture.model.cancelTranscription()
            fixture.window.setContentSize(CGSize(width: 650, height: TerminalInputAreaModel.initialHeight))
            fixture.model.mode = .commandGenerator
            fixture.model.draft = "Find all Swift files"
            fixture.model.generate(
                context: .init(draft: fixture.model.draft, shell: "zsh", cwd: "/tmp"),
                using: InputAreaPreviewGenerator(), isCurrent: { true })
            await fixture.layout()
            try fixture.attachPreview("\(language)-generating")
            fixture.model.cancelGeneration()
            fixture.model.failGeneration(
                AppLocalization.resolve(
                    AppStrings.Workspace.commandGeneratorShellRequirement, locale: Locale(identifier: language)))
            await fixture.layout()
            try fixture.attachPreview("\(language)-error")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERMIND_INPUT_AREA_SCREENSHOTS"] != nil))
    func exportSubmitButtonAppearanceStates() async throws {
        for colorScheme in [ColorScheme.light, .dark] {
            for language in ["en", "zh-Hans"] {
                let fixture = InputAreaViewFixture(language: language, colorScheme: colorScheme)
                defer { fixture.close() }
                for mode in TerminalInputMode.allCases {
                    fixture.model.mode = mode
                    for hasContent in [true, false] {
                        fixture.model.draft = hasContent ? "find . -name '*.swift'" : ""
                        await fixture.layout()
                        let appearance = colorScheme == .light ? "light" : "dark"
                        let state = hasContent ? "enabled" : "disabled"
                        try fixture.attachPreview("\(language)-\(mode.rawValue)-\(appearance)-\(state)")
                    }
                }
            }
        }
    }

    @Test
    func unmountingTheEditorCancelsItsTranscriptionAndPreservesTheDraft() async throws {
        let fixture = InputAreaViewFixture()
        defer { fixture.close() }
        await fixture.layout()
        fixture.model.draft = "retained"
        fixture.model.startTranscription(using: fixture.transcription)
        await fixture.layout()
        #expect(fixture.model.isTranscribing)
        fixture.controller.rootView = AnyView(EmptyView())
        await fixture.layout()
        #expect(!fixture.model.isTranscribing)
        fixture.speechService.emit(.final("stale"))
        #expect(fixture.model.draft == "retained")
    }

    @Test(arguments: TerminalInputMode.allCases, [160.0, 300, 650])
    func speechKeepsTheEditorLayoutAndDraftAtTheMinimumHeight(mode: TerminalInputMode, width: Double) async throws {
        let fixture = InputAreaViewFixture()
        defer { fixture.close() }
        fixture.model.mode = mode
        fixture.model.draft = "Keep this draft"
        fixture.window.setContentSize(CGSize(width: width, height: TerminalInputAreaModel.initialHeight))
        await fixture.layout()
        let editor = try #require(fixture.editor)
        let scroll = try #require(editor.enclosingScrollView)
        let frame = scroll.convert(scroll.bounds, to: fixture.controller.view)
        #expect(frame.height > 0 && fixture.controller.view.bounds.contains(frame))
        let selection = NSRange(location: 5, length: 4)
        editor.setSelectedRange(selection)

        fixture.model.startTranscription(using: fixture.transcription)
        await fixture.layout()
        #expect(fixture.transcription.phase == .recording)
        #expect(fixture.editor === editor)
        #expect(scroll.convert(scroll.bounds, to: fixture.controller.view) == frame)
        #expect(editor.selectedRange() == selection)
        fixture.model.stopTranscription()
        await fixture.layout()
        #expect(fixture.transcription.phase == .transcribing)
        #expect(scroll.convert(scroll.bounds, to: fixture.controller.view) == frame)
        fixture.model.cancelTranscription()
        await fixture.layout()
        #expect(fixture.editor === editor && editor.string == "Keep this draft")
        #expect(scroll.convert(scroll.bounds, to: fixture.controller.view) == frame)
        #expect(fixture.model.mode == mode && fixture.sent.isEmpty)
        #expect(!fixture.window.isVisible)
    }
}

@MainActor
private final class InputAreaPreviewGenerator: CommandGenerating {
    func generate(_ context: CommandGeneratorContext) async throws -> String {
        try await Task.sleep(for: .seconds(60))
        return "find . -name '*.swift'"
    }
}

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct TerminalInputModelMenuTests {
    @Test
    func modelPickerOpensDirectlyToModelsWithoutEffortOrContextSections() async throws {
        let fixture = InputAreaViewFixture()
        defer { fixture.close() }
        fixture.model.mode = .commandGenerator
        fixture.controller.rootView = AnyView(
            TerminalInputModelMenu(ai: fixture.ai, compact: false, selectionChanged: {}, configure: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        fixture.window.makeKeyAndOrderFront(nil)
        await fixture.layout()
        let capture = InputAreaModelMenuCapture()
        NotificationCenter.default.addObserver(
            capture, selector: #selector(InputAreaModelMenuCapture.menuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil)
        defer { NotificationCenter.default.removeObserver(capture) }
        let view = fixture.controller.view
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: center, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            fixture.window.sendEvent(event)
        }
        let menu = try #require(capture.menu)
        #expect(menu.items.contains { $0.title == "Example Model" && $0.submenu == nil })
        #expect(
            !menu.items.contains { $0.title == "Model" || $0.title.contains("Effort") || $0.title.contains("Context") })
        let fallback = try #require(menu.items.firstIndex { $0.title == AIRole.commandGenerator.unsetLabel })
        let chatRole = fixture.ai.assignment(for: .chat)
        menu.performActionForItem(at: fallback)
        await fixture.layout()
        #expect(fixture.ai.assignment(for: .commandGenerator) == nil)
        #expect(fixture.ai.assignment(for: .chat) == chatRole)
        #expect(fixture.model.draft.isEmpty && fixture.sent.isEmpty)
    }
}

@MainActor
private final class InputAreaModelMenuCapture: NSObject {
    var menu: NSMenu?

    @objc func menuDidBeginTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        self.menu = menu
        let timer = Timer(timeInterval: 0.1, repeats: false) { [self] _ in
            MainActor.assumeIsolated {
                self.menu?.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct TerminalInputAreaFocusTests {
    @Test(arguments: InputSendShortcut.allCases)
    func sendShortcutBelongsOnlyToTheActiveEditorAndSendingKeepsFocus(shortcut: InputSendShortcut) async throws {
        let fixture = InputAreaViewFixture(sendShortcut: shortcut)
        defer { fixture.close() }
        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await fixture.layout()
        let editor = try #require(fixture.editor)
        #expect(fixture.window.makeFirstResponder(editor))
        fixture.model.draft = "echo ready"
        await fixture.layout()
        for _ in 0..<100 where !fixture.window.isKeyWindow {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            fixture.window.orderFrontRegardless()
            fixture.window.makeMain()
            fixture.window.makeKey()
            try await Task.sleep(for: .milliseconds(20))
        }
        if !fixture.window.isKeyWindow {
            Attachment.record(
                Data(
                    """
                    appActive=\(NSApp.isActive), activationPolicy=\(NSApp.activationPolicy().rawValue)
                    visible=\(fixture.window.isVisible), canBecomeKey=\(fixture.window.canBecomeKey)
                    keyWindow=\(String(describing: NSApp.keyWindow)), modalWindow=\(String(describing: NSApp.modalWindow))
                    frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")
                    responder=\(String(describing: fixture.window.firstResponder))
                    """.utf8),
                named: "terminal-input-focus.txt")
        }
        try #require(fixture.window.isKeyWindow)
        #expect(fixture.window.makeFirstResponder(editor))
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: shortcut == .returnKey ? [] : .command, timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: event)
        await fixture.layout()
        #expect(fixture.sent == ["echo ready"])
        #expect(fixture.model.draft.isEmpty)
        #expect(fixture.window.firstResponder === editor)

        fixture.model.draft = "must not send"
        await fixture.layout()
        editor.acceptsSubmission = false
        editor.keyDown(with: event)
        #expect(fixture.sent.count == 1)
        editor.acceptsSubmission = true
        editor.setMarkedText(
            "input", selectedRange: NSRange(location: 5, length: 0), replacementRange: editor.selectedRange())
        editor.keyDown(with: event)
        #expect(fixture.sent.count == 1)
        editor.unmarkText()

        fixture.model.draft = "generate from Input mode"
        await fixture.layout()
        #expect(fixture.model.mode == .input)
        let generate = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil,
                characters: "i", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34))
        #expect(editor.performKeyEquivalent(with: generate))
        #expect(fixture.generationRequests == ["generate from Input mode"])
        #expect(TerminalInputTextView.generateInFocusedEditor(in: fixture.window))
        #expect(fixture.generationRequests.count == 2)
        editor.setMarkedText(
            "input", selectedRange: NSRange(location: 5, length: 0), replacementRange: editor.selectedRange())
        #expect(editor.performKeyEquivalent(with: generate))
        #expect(TerminalInputTextView.generateInFocusedEditor(in: fixture.window))
        #expect(fixture.generationRequests.count == 2)
        editor.unmarkText()

        let other = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.makeKeyAndOrderFront(nil)
        await fixture.layout()
        _ = editor.performKeyEquivalent(with: event)
        #expect(fixture.sent.count == 1)
        #expect(!TerminalInputTextView.generateInFocusedEditor(in: fixture.window))
        _ = editor.performKeyEquivalent(with: generate)
        #expect(fixture.generationRequests.count == 2)
    }
}

@MainActor
private final class InputAreaViewFixture {
    let model: TerminalInputAreaModel
    let speechService = TerminalInputSpeechService()
    let transcription: SpeechTranscriptionCoordinator
    let ai: AIConfigurationModel
    let controller: NSHostingController<AnyView>
    let window: NSWindow
    private let suite = "TerminalInputAreaLayoutTests.\(UUID())"
    private let defaults: UserDefaults
    var sent: [String] { submissions.values }
    var generationRequests: [String] { submissions.generationRequests }
    private let submissions = Submissions()

    private final class Submissions {
        var values: [String] = []
        var generationRequests: [String] = []
    }

    init(
        language: String = "en", colorScheme: ColorScheme = .light,
        sendShortcut: InputSendShortcut = .returnKey
    ) {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(sendShortcut.rawValue, forKey: SettingsKey.inputSendShortcut)
        let model = TerminalInputAreaModel(defaults: defaults)
        self.model = model
        let transcription = SpeechTranscriptionCoordinator(service: speechService)
        self.transcription = transcription
        let provider = ModelProvider(name: "Preview", models: [AIModel(id: "Example Model")])
        let ai = AIConfigurationModel(modelProviders: [provider], persistsSecrets: false)
        ai.assign(.init(modelProviderID: provider.id, modelID: "Example Model"), to: .commandGenerator)
        self.ai = ai
        let submissions = submissions
        controller = NSHostingController(
            rootView: AnyView(
                TerminalInputAreaView(
                    model: model, availableHeight: 600, isActive: true,
                    transcription: transcription, ai: ai, configureModels: {}, focusPane: {},
                    send: { model.submit { submissions.values.append($0) } },
                    generate: { submissions.generationRequests.append(model.draft) }
                )
                .environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, colorScheme)
                .defaultAppStorage(defaults)
                .transaction { $0.disablesAnimations = true }
            )
        )
        controller.sizingOptions = []
        let size = CGSize(width: 650, height: TerminalInputAreaModel.initialHeight)
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: colorScheme == .light ? .aqua : .darkAqua)
        window.contentViewController = controller
        window.setContentSize(size)
        controller.view.frame = CGRect(origin: .zero, size: size)
    }

    var editor: TerminalInputTextView? {
        descendants(controller.view).compactMap { $0 as? TerminalInputTextView }.first
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func attachPreview(_ name: String) throws {
        let view = controller.view
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        Attachment.record(png, named: "terminal-input-\(name).png")
    }

    func layout() async {
        controller.view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        controller.view.layoutSubtreeIfNeeded()
    }

    func close() {
        model.close()
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }
}

nonisolated private struct InputAreaInertSerialService: SerialPortServing {
    func portUpdates() -> AsyncStream<[SerialPortDescriptor]> { AsyncStream { $0.finish() } }
    func open(
        _ configuration: SerialConnectionConfiguration,
        receive: @escaping @Sendable (Data) -> Void,
        disconnected: @escaping @Sendable (String) -> Void,
        progress: @escaping @Sendable (SerialPortOpenStage) -> Void
    ) async throws -> any SerialPortConnection {
        throw CancellationError()
    }
}
