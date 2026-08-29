import SwiftUI

/// The menu bar.
///
/// Every command routes through `@FocusedValue(\.window)` rather than a global,
/// so ⌘T opens a Workspace in the window you are actually looking at. When no window is
/// frontmost the value is nil and the items disable themselves, which is the
/// correct behaviour and comes for free.
///
/// `AppModel` is passed in rather than read from the environment: `Commands` is
/// not a `View`, so `@Environment` on a custom `@Observable` does not resolve
/// here. It is app-wide and there is exactly one, so injection costs nothing.
struct TermindCommands: Commands {
    let app: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusedValue(\.window) private var window

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // Keep Quick Open inside the replacement group. Placing it in a
            // separate group after `.newItem` makes SwiftUI discard it when
            // this replacement is merged into the final File menu, leaving
            // no menu item (and therefore no working Command-P shortcut).
            Button("Quick Open") { window?.isQuickOpenPresented = true }
                .termindShortcut("p")
                .disabled(window == nil)

            Divider()

            // Both of these act on the host selected on the Hosts page, and fall
            // back to that page when there is none — see `AppModel.newWorkspace`.
            //
            // Ordered by how often they are reached, not alphabetically: a
            // session, then a transfer to the same kind of machine, then a chat
            // that is attached to neither.
            Button("Connect") {
                guard let window else { return }
                app.connect(in: window)
            }
            .termindShortcut("t")
            Button("New Chat") { window?.openNewAssistantChat() }
                .termindShortcut("t", modifiers: [.command, .option])

            Divider()

            Button("New Host") { window?.openHostEditor(host: nil) }
                .termindShortcut("n", modifiers: [.command, .shift])

            Divider()

            // A multi-pane selection is already a Workspace, so Duplicate
            // copies that whole arrangement into one new Workspace. A single pane can
            // instead choose whether its fresh copy belongs beside it or apart.
            if window?.selectedWorkspace?.isSplit == true {
                Button("Duplicate") { window?.duplicateSelectedInNewWorkspace() }
                    .termindShortcut("d")
                    .disabled(!(window?.canDuplicateSelected ?? false))
            } else {
                Menu("Duplicate") {
                    Button("In Current Workspace") {
                        window?.duplicateSelected(axis: .horizontal)
                    }
                    .termindShortcut("d")
                    Button("In New Workspace") { window?.duplicatePaneInNewWorkspace() }
                        .termindShortcut("d", modifiers: [.command, .shift])
                }
                .disabled(!(window?.canDuplicateSelected ?? false))
            }
        }

        CommandGroup(after: .pasteboard) {
            Button("Generate Command") {
                guard app.proAccess.require(.commandGenerator) else { return }
                window?.generateTerminalCommand(using: app.commandGenerator)
            }
            .termindShortcut("i")
            .disabled(!(window?.canGenerateTerminalCommand ?? false))

            Divider()

            // One Find for the whole window: this focuses the field in the
            // titlebar, whatever that field is currently pointed at. See
            // `WindowModel.findKind`.
            Button("Find") { window?.focusToolbarFind() }
                .termindShortcut("f")
                .disabled(!(window?.canFindInMainContent ?? false))

            // `.previous` walks toward older output, which is where the matches
            // are when a search starts at the bottom of the buffer — so it is
            // what "next" means to a reader. Return in the Find field agrees.
            Button("Find Next in Terminal") {
                window?.navigateTerminalFind(.previous)
            }
            .termindShortcut("g")
            .disabled(!(window?.canFindInTerminal ?? false))

            Button("Find Previous in Terminal") {
                window?.navigateTerminalFind(.next)
            }
            .termindShortcut("g", modifiers: [.command, .shift])
            .disabled(!(window?.canFindInTerminal ?? false))
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close Workspace") { window?.closeSelected() }
                .termindShortcut("w")
                .disabled(window?.selectedWorkspace == nil)
            Button("Close Other Workspaces") {
                guard let window, let id = window.selectedWorkspaceID else { return }
                window.closeOthers(than: id)
            }
            .termindShortcut("w", modifiers: [.command, .option])
            .disabled(window?.selectedWorkspace == nil)
            Button("Reopen Closed Workspace") { window?.reopenLastClosed() }
                .termindShortcut("t", modifiers: [.command, .shift])
                .disabled(!(window?.canReopen ?? false))
        }

        // No Session menu. What was in it lives in File (Duplicate),
        // in View (the two Splits), on the pane header (Broadcast Input, which
        // shows its own state right next to the panes it reaches and so does not
        // need a second copy in the menu bar — ⌘B is registered by
        // `WorkspaceContentView`), or nowhere yet: Clear Scrollback, Ask AI About
        // Selection and Suggest a Command were disabled placeholders holding
        // shortcuts for P2/P4, and P2 can put them wherever the real commands
        // end up.
        CommandGroup(after: .sidebar) {
            Button("Show Assistant in Sidebar") {
                guard let window else { return }
                withAnimation(Motion.panel(reduceMotion: reduceMotion)) {
                    window.showAssistant()
                }
            }
            .termindShortcut("i", modifiers: [.command, .option])
            .disabled(window?.selectedWorkspace == nil)

            Divider()

            // No modifier duplicates, ⌥ carves an empty slot — the pair that
            // opens a connection and the pair that only rearranges the window
            // are one key apart, and the ⌥ ones never touch the network.
            Button("Split Right") { window?.splitSelected(axis: .horizontal) }
                .termindShortcut("d", modifiers: [.command, .option])
                .disabled(!(window?.canSplitSelected ?? false))
            Button("Split Down") { window?.splitSelected(axis: .vertical) }
                .termindShortcut("d", modifiers: [.command, .option, .shift])
                .disabled(!(window?.canSplitSelected ?? false))
        }

        CommandGroup(before: .windowList) {
            Button("Next Workspace") { window?.selectNext() }
                .termindShortcut(.tab, modifiers: .control)
                .disabled(window?.workspaces.isEmpty != false)
            Button("Previous Workspace") { window?.selectPrevious() }
                .termindShortcut(.tab, modifiers: [.control, .shift])
                .disabled(window?.workspaces.isEmpty != false)
            Button("Show Next Workspace") { window?.selectNext() }
                .termindShortcut("]", modifiers: [.command, .shift])
                .disabled(window?.workspaces.isEmpty != false)
            Button("Show Previous Workspace") { window?.selectPrevious() }
                .termindShortcut("[", modifiers: [.command, .shift])
                .disabled(window?.workspaces.isEmpty != false)

            Divider()

            // ⌘1…⌘8 by sidebar position, ⌘9 to the last Workspace — the convention every
            // browser and terminal shares.
            ForEach(1...8, id: \.self) { index in
                Button("Workspace \(index)") { window?.select(index: index - 1) }
                    .termindShortcut(AppShortcutKey.character(Character("\(index)")))
                    .disabled((window?.workspaces.count ?? 0) < index)
            }
            Button("Last Workspace") {
                guard let window else { return }
                window.select(index: window.workspaces.count - 1)
            }
            .termindShortcut("9")
            .disabled(window?.workspaces.isEmpty != false)

            Divider()
        }

        CommandGroup(replacing: .help) {
            Link("Support", destination: URL(string: "https://termind.akinokaede.com/support/")!)
        }
    }
}
