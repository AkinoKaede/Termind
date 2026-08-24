#if canImport(AppKit)
    import AppKit
    import GhosttyTerminal
    import SwiftUI

    /// Mounts one long-lived Ghostty view into whichever pane currently owns it.
    ///
    /// Moving a pane changes its position in `SplitNode`, which changes the
    /// SwiftUI parent chain. SwiftUI is allowed to dismantle and recreate an
    /// `NSViewRepresentable` across that move even when the pane keeps the same
    /// `.id`. A newly created `TerminalView` would make Ghostty replace the
    /// surface attached to the shared controller, losing the visible grid and
    /// scrollback.
    ///
    /// The owner below lives with `SSHSessionModel`, not with the transient
    /// representable. Reparenting therefore moves the same native view and the
    /// same surface into the new container instead of constructing either one.
    struct PersistentTerminalSurfaceView: NSViewRepresentable {
        let state: TerminalViewState
        let owner: PersistentTerminalViewOwner
        let isVisible: Bool
        let requestsFocus: Bool

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
                requestsFocus: requestsFocus
            )
            return container
        }

        func updateNSView(_ container: TerminalMountView, context _: Context) {
            owner.mount(
                in: container,
                state: state,
                isVisible: isVisible,
                requestsFocus: requestsFocus
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

    /// Keeps application-owned shortcuts in AppKit's menu command chain.
    ///
    /// Ghostty recognizes several application commands while the terminal is
    /// first responder. Returning `true` prevents SwiftUI's menu command from
    /// seeing the event. Let Termind's tab and find shortcuts fall through; every
    /// other key still uses Ghostty's input path.
    private final class TermindTerminalView: TerminalView {
        var inputCapture: TerminalInteractiveInputCapture?

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
            if Self.isApplicationShortcut(event) { return false }
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

        private static func isApplicationShortcut(_ event: NSEvent) -> Bool {
            guard event.type == .keyDown else { return false }
            // Caps Lock, Function and Numeric Pad do not change the shortcut.
            // Only the four modifiers users combine into menu commands matter.
            let commandModifiers: NSEvent.ModifierFlags = [
                .command, .control, .option, .shift,
            ]
            let modifiers = event.modifierFlags.intersection(commandModifiers)
            let character = event.charactersIgnoringModifiers?.lowercased()

            if event.keyCode == 53, modifiers.isEmpty || modifiers == .shift {
                // Esc/⇧Esc close an open find bar. With no enabled find command
                // AppKit falls back to keyDown and the shell still receives Esc.
                return true
            }

            switch character {
            case "b":
                return modifiers == .command
            case "q":
                return modifiers == .command
            case "w":
                return modifiers == .command
            case "f":
                return modifiers == .command
            case "g":
                return modifiers == .command || modifiers == [.command, .shift]
            default:
                // F3 and ⇧F3 are secondary VS Code terminal-find bindings.
                guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first?.value
                else { return false }
                return scalar == UInt32(NSF3FunctionKey)
                    && (modifiers.isEmpty || modifiers == .shift)
            }
        }
    }

    /// Strong owner for the native terminal view. There is exactly one of these
    /// per `SSHSessionModel`, so SplitNode mutations cannot change native
    /// view identity or trigger a Ghostty surface rebuild.
    @MainActor
    final class PersistentTerminalViewOwner {
        private let terminalView: TermindTerminalView
        private weak var container: TerminalMountView?
        private var mountConstraints: [NSLayoutConstraint] = []
        private var appliedVisibility: Bool?
        private var wantsFocus = false
        private var nextMountOrdinal: UInt64 = 0

        private var ownerIdentifier: ObjectIdentifier { ObjectIdentifier(self) }

        init(
            state: TerminalViewState,
            inputCapture: TerminalInteractiveInputCapture
        ) {
            let terminal = TermindTerminalView(frame: .zero)
            terminal.inputCapture = inputCapture
            terminal.translatesAutoresizingMaskIntoConstraints = false
            terminal.delegate = state
            terminal.configuration = state.configuration
            terminal.controller = state.controller
            terminalView = terminal
        }

        /// Idempotent: ordinary SwiftUI updates stop after the reference checks.
        /// Only a real pane move removes the terminal from one container and
        /// constrains it to another.
        func mount(
            in newContainer: TerminalMountView,
            state: TerminalViewState,
            isVisible: Bool,
            requestsFocus: Bool
        ) {
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
            }

            // The controller and options are established once by the session.
            // Do not stamp options during ordinary updates: the dependency's
            // equivalence helper is intentionally internal, and assigning a
            // value it considers different tears down the live surface.
            if terminalView.controller !== state.controller {
                terminalView.controller = state.controller
            }
            if appliedVisibility != isVisible {
                appliedVisibility = isVisible
                terminalView.setSurfaceVisible(isVisible)
            }

            synchronizeFocus(requested: requestsFocus && isVisible)
        }

        func unmount(from oldContainer: TerminalMountView) {
            // SwiftUI may build the destination before dismantling the source.
            // A late dismantle callback for the old container must not detach
            // the terminal that has already reached its new pane.
            guard container === oldContainer,
                terminalView.superview === oldContainer
            else { return }

            NSLayoutConstraint.deactivate(mountConstraints)
            mountConstraints.removeAll(keepingCapacity: true)
            terminalView.removeFromSuperview()
            oldContainer.owner = nil
            container = nil
        }

        func requestFocus() {
            synchronizeFocus(requested: true)
        }

        @discardableResult
        func performBindingAction(_ action: String) -> Bool {
            terminalView.performBindingAction(action)
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

        private func synchronizeFocus(requested: Bool) {
            wantsFocus = requested
            guard let window = terminalView.window else {
                if requested { scheduleFocusAfterMount() }
                return
            }

            if requested {
                if window.firstResponder !== terminalView {
                    window.makeFirstResponder(terminalView)
                }
            } else if window.firstResponder === terminalView {
                window.makeFirstResponder(nil)
            }
        }

        private func scheduleFocusAfterMount() {
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
                if window.firstResponder !== terminalView {
                    window.makeFirstResponder(terminalView)
                }
            }
        }
    }
#endif
