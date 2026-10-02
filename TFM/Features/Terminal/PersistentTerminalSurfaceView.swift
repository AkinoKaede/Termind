#if canImport(AppKit)
    import AppKit
    import GhosttyTerminal
    import SwiftUI
    import TermindApplication
    import TermindPresentation

    /// Mounts one long-lived Ghostty view into whichever pane currently owns it.
    ///
    /// Moving a pane changes its position in `SplitNode`, which changes the
    /// SwiftUI parent chain. SwiftUI is allowed to dismantle and recreate an
    /// `NSViewRepresentable` across that move even when the pane keeps the same
    /// `.id`. A newly created `TerminalView` would make Ghostty replace the
    /// surface attached to the shared controller, losing the visible grid and
    /// scrollback.
    ///
    /// The owner below lives with its terminal session model, not with the
    /// transient representable. Reparenting therefore moves the same native view
    /// and surface into the new container instead of constructing either one.
    struct PersistentTerminalSurfaceView: NSViewRepresentable {
        let state: TerminalViewState
        let owner: PersistentTerminalViewOwner
        let isVisible: Bool
        let requestsFocus: Bool
        @AppStorage(SettingsKey.terminalCopyOnSelect) private var copyOnSelect = false
        @AppStorage(SettingsKey.terminalPasteOnRightClick) private var pasteOnRightClick = false

        final class Coordinator {
            let owner: PersistentTerminalViewOwner

            init(owner: PersistentTerminalViewOwner) {
                self.owner = owner
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(owner: owner)
        }

        func makeNSView(context _: Context) -> TerminalMountView {
            let container = TerminalMountView()
            owner.mount(
                in: container,
                state: state,
                isVisible: isVisible,
                requestsFocus: requestsFocus,
                copyOnSelect: copyOnSelect,
                pasteOnRightClick: pasteOnRightClick
            )
            return container
        }

        func updateNSView(_ container: TerminalMountView, context _: Context) {
            owner.mount(
                in: container,
                state: state,
                isVisible: isVisible,
                requestsFocus: requestsFocus,
                copyOnSelect: copyOnSelect,
                pasteOnRightClick: pasteOnRightClick
            )
        }

        static func dismantleNSView(
            _ container: TerminalMountView,
            coordinator: Coordinator
        ) {
            // The container may already have been reused for a different pane.
            // Unmount only the owner represented by the view being dismantled;
            // asking `container.owner` here could detach the newly mounted pane.
            coordinator.owner.unmount(from: container)
        }
    }

    /// A deliberately inert SwiftUI/AppKit boundary. Ghostty owns all drawing
    /// and input; this view supplies only stable geometry and a mount point.
    final class TerminalMountView: NSView {
        weak var owner: PersistentTerminalViewOwner?
        /// SwiftUI can reuse this NSView for another session while rebuilding a
        /// split tree. Keep a generation for every owner that has visited it so
        /// a late update from an older tree cannot steal it back.
        fileprivate var mountOrdinals: [ObjectIdentifier: UInt64] = [:]

        override var isOpaque: Bool { false }
    }

    /// Adds desktop mouse preferences and keeps application-owned shortcuts in
    /// AppKit's menu command chain.
    ///
    /// Ghostty recognizes several application commands while the terminal is
    /// first responder. Returning `true` prevents SwiftUI's command owner from
    /// seeing the event. Registered Termind shortcuts fall through; every other
    /// key still uses Ghostty's input path.
    final class TermindTerminalView: TerminalView {
        var uploadFiles: (() -> Void)?
        var canUploadFiles: (() -> Bool)?
        var inputCapture: TerminalInteractiveInputCapture?
        var copyOnSelect = false
        var pasteOnRightClick = false
        private var isSelectingWithMouse = false
        private var rightClickPastes: Bool?
        private var isPathDropVisible = false

        override func setSurfaceVisible(_ visible: Bool) {
            super.setSurfaceVisible(visible)
            isPathDropVisible = visible
            updatePathDropRegistration()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updatePathDropRegistration()
        }

        private func updatePathDropRegistration() {
            if isPathDropVisible, window != nil {
                registerForDraggedTypes([TerminalPathDrag.pasteboardType])
            } else {
                unregisterDraggedTypes()
            }
        }

        /// Registration alone cannot cancel a drag AppKit already dispatched
        /// before this workspace became hidden. Recheck at every entry point.
        func pathDropOperation(
            from pasteboard: NSPasteboard, sourceOperations: NSDragOperation
        ) -> NSDragOperation {
            guard isPathDropVisible, window != nil, superview != nil,
                !isHiddenOrHasHiddenAncestor, sourceOperations.contains(.copy),
                TerminalPathDrag.text(from: pasteboard) != nil
            else { return [] }
            // AppKit supplies the green circle with a white plus cursor badge.
            return .copy
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            pathDropOperation(from: sender.draggingPasteboard, sourceOperations: sender.draggingSourceOperationMask)
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            pathDropOperation(from: sender.draggingPasteboard, sourceOperations: sender.draggingSourceOperationMask)
        }

        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            draggingUpdated(sender) == .copy
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            receivePathDrop(from: sender.draggingPasteboard, sourceOperations: sender.draggingSourceOperationMask)
        }

        func receivePathDrop(from pasteboard: NSPasteboard, sourceOperations: NSDragOperation) -> Bool {
            guard pathDropOperation(from: pasteboard, sourceOperations: sourceOperations) == .copy,
                let text = TerminalPathDrag.text(from: pasteboard)
            else { return false }
            return pasteDroppedPath(text)
        }

        func pasteDroppedPath(_ text: String) -> Bool {
            guard isPathDropVisible, window != nil, superview != nil,
                !isHiddenOrHasHiddenAncestor, !text.isEmpty
            else { return false }
            acquireProgrammaticFocus()
            return captureInteraction { paste(text: text) }
        }

        override func mouseDown(with event: NSEvent) {
            // Remote mouse reports must never copy an unrelated retained selection.
            isSelectingWithMouse = !isMouseCaptured
            super.mouseDown(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            let shouldCopy = isSelectingWithMouse && copyOnSelect
            isSelectingWithMouse = false
            super.mouseUp(with: event)
            if shouldCopy { _ = copySelectedTextToPasteboard() }
        }

        override func rightMouseDown(with event: NSEvent) {
            let pastes = shouldPasteOnRightClick(event)
            rightClickPastes = pastes
            if pastes {
                acquireProgrammaticFocus()
            } else {
                super.rightMouseDown(with: event)
            }
        }

        override func rightMouseDragged(with event: NSEvent) {
            if rightClickPastes == false { super.rightMouseDragged(with: event) }
        }

        override func rightMouseUp(with event: NSEvent) {
            guard let pastes = rightClickPastes else { return }
            rightClickPastes = nil
            if pastes {
                // An empty paste must not arm a deferred broadcast ticket that
                // could consume the next unrelated mouse or protocol report.
                guard canPasteFromClipboard else { return }
                captureInteraction { _ = performBindingAction("paste_from_clipboard") }
            } else {
                super.rightMouseUp(with: event)
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard !isMouseCaptured else { return nil }
            if event.type == .rightMouseDown || event.type == .rightMouseUp,
                rightClickPastes ?? shouldPasteOnRightClick(event)
            {
                return nil
            }
            return super.menu(for: event)
        }

        override func selectionMenuPoint(at point: CGPoint) -> CGPoint? {
            // The superclass uses this hook to decide whether a right-click
            // presents a menu. Offer the app's default menu without a selection too.
            isMouseCaptured ? nil : point
        }

        override func selectionContextMenu() -> NSMenu {
            let menu: NSMenu
            if super.selectionMenuPoint(at: .zero) != nil {
                menu = super.selectionContextMenu()
                menu.items.first?.title = String(localized: AppStrings.Common.copy)
            } else {
                menu = NSMenu()
            }
            menu.autoenablesItems = false
            let pasteItem = NSMenuItem(
                title: String(localized: AppStrings.Common.paste),
                action: #selector(pasteFromContextMenu(_:)), keyEquivalent: "")
            pasteItem.target = self
            pasteItem.isEnabled = canPasteFromClipboard
            menu.addItem(pasteItem)
            let selectAllItem = NSMenuItem(
                title: String(localized: AppStrings.Common.selectAll),
                action: #selector(selectAll(_:)), keyEquivalent: "")
            selectAllItem.target = self
            menu.addItem(selectAllItem)
            if uploadFiles != nil {
                menu.addItem(.separator())
                let upload = NSMenuItem(
                    title: String(localized: AppStrings.Terminal.uploadFile),
                    action: #selector(uploadFromContextMenu(_:)), keyEquivalent: "")
                upload.target = self
                upload.isEnabled = canUploadFiles?() == true
                menu.addItem(upload)
            }
            return menu
        }

        @objc private func uploadFromContextMenu(_: Any?) {
            guard canUploadFiles?() == true else { return }
            uploadFiles?()
        }

        private var canPasteFromClipboard: Bool {
            let pasteboard = NSPasteboard.general
            return pasteboard.string(forType: .string)?.isEmpty == false
                || pasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
        }

        @objc private func pasteFromContextMenu(_: Any?) {
            guard canPasteFromClipboard else { return }
            captureInteraction { _ = performBindingAction("paste_from_clipboard") }
        }

        private func shouldPasteOnRightClick(_ event: NSEvent) -> Bool {
            pasteOnRightClick && !isMouseCaptured && !event.modifierFlags.contains(.option)
        }

        override func keyDown(with event: NSEvent) {
            captureInteraction { super.keyDown(with: event) }
        }

        override func keyUp(with event: NSEvent) {
            captureInteraction(allowsDeferredWrite: false) {
                super.keyUp(with: event)
            }
        }

        override func flagsChanged(with event: NSEvent) {
            captureInteraction(allowsDeferredWrite: false) {
                super.flagsChanged(with: event)
            }
        }

        /// Menu-bar Paste reaches the first responder through `tryToPerform`
        /// rather than `keyDown`. Keep the capture alive while AppKit invokes
        /// Ghostty's paste action so bracketed-paste bytes are classified as
        /// interactive input too.
        override func tryToPerform(_ action: Selector, with object: Any?) -> Bool {
            guard action == NSSelectorFromString("paste:") else {
                return super.tryToPerform(action, with: object)
            }
            return captureInteraction {
                super.tryToPerform(action, with: object)
            }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if AppShortcutRegistry.shared.routesToApplication(event) { return false }
            return captureInteraction {
                super.performKeyEquivalent(with: event)
            }
        }

        private func captureInteraction<Result>(
            allowsDeferredWrite: Bool = true,
            _ operation: () -> Result
        ) -> Result {
            guard let inputCapture else { return operation() }
            return inputCapture.withInteraction(
                allowsDeferredWrite: allowsDeferredWrite,
                operation
            )
        }
    }

    /// Strong owner for one terminal backend, state and native view, so SplitNode
    /// mutations cannot change view identity or lose the screen buffer.
    @MainActor
    final class PersistentTerminalViewOwner {
        private let terminalView: TermindTerminalView
        let state: TerminalViewState
        nonisolated private let backend: InMemoryTerminalSession
        private weak var container: TerminalMountView?
        private var mountConstraints: [NSLayoutConstraint] = []
        private var appliedVisibility: Bool?
        private var wantsFocus = false
        private var nextMountOrdinal: UInt64 = 0

        func configureUpload(action: (() -> Void)?, isAvailable: (() -> Bool)? = nil) {
            terminalView.uploadFiles = action
            terminalView.canUploadFiles = isAvailable
        }

        func chooseUploadFiles(completion: @escaping ([URL]) -> Void) {
            guard isUploadSurfaceVisible, let window = terminalView.window else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, self?.isUploadSurfaceVisible == true else { return }
                completion(panel.urls)
            }
        }

        var isUploadSurfaceVisible: Bool {
            appliedVisibility == true && terminalView.window != nil && !terminalView.isHiddenOrHasHiddenAncestor
        }

        func pasteUploadedText(_ text: String) {
            terminalView.inputCapture?.withLocalPaste { _ = state.paste(text: text) }
        }

        private var ownerIdentifier: ObjectIdentifier { ObjectIdentifier(self) }

        init(
            write: @escaping @Sendable (Data, Bool) -> Void,
            resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void
        ) {
            let inputCapture = TerminalInteractiveInputCapture()
            let backend = InMemoryTerminalSession(
                write: { data in write(data, inputCapture.classifyWrite(data)) },
                resize: resize,
                suppressesPixelOnlyResizes: true
            )
            let state = TerminalViewState(configSource: .none)
            state.configuration = TerminalSurfaceOptions(
                backend: .inMemory(backend), resizeThrottleMilliseconds: 35
            )
            self.backend = backend
            self.state = state
            let terminal = TermindTerminalView(frame: .zero)
            terminal.inputCapture = inputCapture
            terminal.translatesAutoresizingMaskIntoConstraints = false
            terminal.delegate = state
            terminal.configuration = state.configuration
            terminal.controller = state.controller
            terminalView = terminal
        }

        nonisolated func receive(_ data: Data) {
            backend.receive(data)
        }

        nonisolated func readViewportText() -> String? {
            backend.readViewportText()
        }

        /// Pane overlays own native drop routing above the embedded surface.
        @discardableResult
        func pasteDroppedPath(_ text: String) -> Bool {
            terminalView.pasteDroppedPath(text)
        }

        func appendNotice(_ message: String) {
            receive(Data("\r\n\u{001B}[2m[Termind] \(message)\u{001B}[0m\r\n".utf8))
        }

        /// Idempotent: ordinary SwiftUI updates stop after the reference checks.
        /// Only a real pane move removes the terminal from one container and
        /// constrains it to another.
        func mount(
            in newContainer: TerminalMountView,
            state: TerminalViewState,
            isVisible: Bool,
            requestsFocus: Bool,
            copyOnSelect: Bool = false,
            pasteOnRightClick: Bool = false
        ) {
            var didReparent = false
            if container !== newContainer || terminalView.superview !== newContainer {
                assignOrdinalIfNeeded(to: newContainer)
                // A tree replacement can create the destination before
                // dismantling the source. SwiftUI may still send an update to
                // that older container afterwards; it must not steal the native
                // terminal back from the newer layout.
                if let currentOrdinal = container?.mountOrdinals[ownerIdentifier],
                    let proposedOrdinal = newContainer.mountOrdinals[ownerIdentifier],
                    proposedOrdinal < currentOrdinal
                {
                    return
                }

                // A structural rewrite may hand this representable an AppKit
                // container that still holds another session. Detach that
                // session from this container before claiming it; its own
                // update will mount it into the corresponding destination.
                if let displacedOwner = newContainer.owner, displacedOwner !== self {
                    displacedOwner.unmount(from: newContainer)
                }
                move(to: newContainer)
                didReparent = true
            }

            // The controller and options are established once by the session.
            // Do not stamp options during ordinary updates: the dependency's
            // equivalence helper is intentionally internal, and assigning a
            // value it considers different tears down the live surface.
            if terminalView.controller !== state.controller {
                terminalView.controller = state.controller
            }
            terminalView.copyOnSelect = copyOnSelect
            terminalView.pasteOnRightClick = pasteOnRightClick
            if appliedVisibility != isVisible {
                appliedVisibility = isVisible
                state.isSurfaceVisible = isVisible
                terminalView.setSurfaceVisible(isVisible)
            }

            synchronizeFocus(
                requested: requestsFocus && isVisible,
                force: false,
                reparented: didReparent
            )
        }

        func unmount(from oldContainer: TerminalMountView) {
            // SwiftUI may build the destination before dismantling the source.
            // A late dismantle callback for the old container must not detach
            // the terminal that has already reached its new pane.
            guard container === oldContainer,
                terminalView.superview === oldContainer
            else { return }

            state.isSurfaceVisible = false
            appliedVisibility = false
            terminalView.setSurfaceVisible(false)
            NSLayoutConstraint.deactivate(mountConstraints)
            mountConstraints.removeAll(keepingCapacity: true)
            terminalView.removeFromSuperview()
            oldContainer.owner = nil
            container = nil
        }

        /// An explicit hand-back — Escape in the Find field, a pane becoming
        /// focused. This one is allowed to take the keyboard away from a text
        /// field, because taking it away is the whole point.
        func requestFocus() {
            synchronizeFocus(requested: true, force: true)
        }

        @discardableResult
        func performBindingAction(_ action: String) -> Bool {
            // Ghostty may make its surface first responder while dispatching a
            // search binding. Preserve an active AppKit field editor in the
            // same call stack so terminal search never produces a visible
            // search-field → terminal → search-field focus flash.
            let window = terminalView.window
            let editor = window?.firstResponder as? NSTextView
            let textField =
                editor?.isFieldEditor == true
                ? editor?.delegate as? NSTextField
                : nil
            let selection = editor?.selectedRange

            let handled = terminalView.performBindingAction(action)

            if let window, let textField,
                window.firstResponder !== textField,
                window.firstResponder !== textField.currentEditor()
            {
                window.makeFirstResponder(textField)
                if let selection {
                    textField.currentEditor()?.selectedRange = selection
                }
            }
            return handled
        }

        #if DEBUG
            var hasKeyboardFocusForTesting: Bool {
                terminalView.window?.firstResponder === terminalView
            }

            func performKeyEquivalentForTesting(_ event: NSEvent) -> Bool {
                terminalView.performKeyEquivalent(with: event)
            }
        #endif

        private func move(to newContainer: TerminalMountView) {
            state.isSurfaceVisible = false
            appliedVisibility = false
            terminalView.setSurfaceVisible(false)
            NSLayoutConstraint.deactivate(mountConstraints)
            mountConstraints.removeAll(keepingCapacity: true)
            terminalView.removeFromSuperview()

            container?.owner = nil
            container = newContainer
            newContainer.owner = self
            newContainer.addSubview(terminalView)

            mountConstraints = [
                terminalView.leadingAnchor.constraint(equalTo: newContainer.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: newContainer.trailingAnchor),
                terminalView.topAnchor.constraint(equalTo: newContainer.topAnchor),
                terminalView.bottomAnchor.constraint(equalTo: newContainer.bottomAnchor),
            ]
            NSLayoutConstraint.activate(mountConstraints)
        }

        private func assignOrdinalIfNeeded(to container: TerminalMountView) {
            guard container.mountOrdinals[ownerIdentifier] == nil else { return }
            nextMountOrdinal &+= 1
            container.mountOrdinals[ownerIdentifier] = nextMountOrdinal
        }

        /// Moves the keyboard to or from the terminal — but only when something
        /// actually asked for it to move.
        ///
        /// `mount` re-runs for *any* observed change on the session, which
        /// includes each letter typed into the window's Find field, and each of
        /// those used to re-assert first responder here. Answering an unchanged
        /// request with a first-responder call is not idempotent: it takes the
        /// caret out of whatever holds it. So an ordinary update now stops at
        /// the first guard and never touches the responder chain at all.
        ///
        /// `force` is the explicit hand-back — Escape in the Find field, or a
        /// pane being focused — and always acts. `reparented` covers the pane
        /// move, where the request has not changed but the view has.
        ///
        /// `isEditingText` stays as a second line of defence for the remaining
        /// unforced case, where the request really did change while somebody was
        /// typing somewhere else.
        private func synchronizeFocus(
            requested: Bool,
            force: Bool,
            reparented: Bool = false
        ) {
            let changed = requested != wantsFocus
            wantsFocus = requested
            guard force || changed || reparented else { return }

            guard let window = terminalView.window else {
                if requested { scheduleFocusAfterMount(force: force) }
                return
            }

            if requested {
                guard window.firstResponder !== terminalView else { return }
                guard force || !isEditingText(in: window) else { return }
                window.makeFirstResponder(terminalView)
            } else if window.firstResponder === terminalView {
                window.makeFirstResponder(nil)
            }
        }

        /// Whether the window's keyboard focus is in a text field. A focused
        /// `NSTextField` or `NSSearchField` delegates to a shared field editor,
        /// so the first responder is usually that `NSTextView` rather than the
        /// control the user sees.
        private func isEditingText(in window: NSWindow) -> Bool {
            switch window.firstResponder {
            case let textView as NSTextView: textView.isFieldEditor
            case is NSTextField: true
            default: false
            }
        }

        private func scheduleFocusAfterMount(force: Bool) {
            // Mounting commonly happens inside a SwiftUI update, before the new
            // container has a window. One run-loop hop lets AppKit finish the
            // reparent without retaining a task or polling layout state.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                    wantsFocus,
                    appliedVisibility == true,
                    let window = terminalView.window,
                    container != nil
                else { return }
                // Same rule as the synchronous path, and it carries `force` for
                // the same reason. A hop later is exactly when the Find field
                // has just taken the caret, and this used to be the one route to
                // first responder with no guard on it at all.
                guard force || !isEditingText(in: window) else { return }
                if window.firstResponder !== terminalView {
                    window.makeFirstResponder(terminalView)
                }
            }
        }
    }
#endif
