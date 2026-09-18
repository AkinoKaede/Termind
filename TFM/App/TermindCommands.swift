import SwiftUI
import TermindDomain

import struct TermindDomain.Host

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
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.window) private var window

    private var closeTitle: LocalizedStringKey {
        guard let workspace = window?.selectedWorkspace else { return "Close Window" }
        return workspace.isSplit ? "Close Pane" : "Close Workspace"
    }

    private var newWindowConnects: Bool { app.mainWindows.isFullScreen(window) }
    private var newWindowTitle: LocalizedStringKey { newWindowConnects ? "Connect" : "New Window" }

    var body: some Commands {
        let _ = app.mainWindows.registerWindowCreation { [openWindow] id in
            openWindow(id: "main", value: id)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings", systemImage: MenuSymbol.settings) { window?.openSettings() }
                .termindShortcut(",")
                .disabled(window == nil)
        }

        CommandGroup(replacing: .newItem) {
            Button(
                newWindowTitle,
                systemImage: newWindowConnects ? MenuSymbol.ssh : MenuSymbol.newWindow
            ) {
                app.mainWindows.performNewWindowCommand(from: window)
            }
            .termindShortcut("n")

            Divider()

            // Keep Quick Open inside the replacement group. Placing it in a
            // separate group after `.newItem` makes SwiftUI discard it when
            // this replacement is merged into the final File menu, leaving
            // no menu item (and therefore no working Command-P shortcut).
            Button("Quick Open", systemImage: MenuSymbol.quickOpen) {
                app.onboarding.recordUse(of: .quickOpen)
                window?.isQuickOpenPresented = true
            }
            .termindShortcut("p")
            .disabled(window == nil)

            Divider()

            // Both of these act on the host selected on the Hosts page, and fall
            // back to that page when there is none — see `AppModel.newWorkspace`.
            //
            // Ordered by how often they are reached, not alphabetically: a
            // session, then a transfer to the same kind of machine, then a chat
            // that is attached to neither.
            Button("Connect", systemImage: MenuSymbol.ssh) {
                guard let window else { return }
                app.connect(in: window)
            }
            .termindShortcut("t")
            Button("New Chat", systemImage: MenuSymbol.newChat) { window?.openNewAssistantChat() }
                .termindShortcut("t", modifiers: [.command, .option])

            Divider()

            Button("New Host", systemImage: MenuSymbol.newHost) { window?.openHostEditor(host: nil) }
                .termindShortcut("n", modifiers: [.command, .shift])

            Divider()

            // A multi-pane selection is already a Workspace, so Duplicate
            // copies that whole arrangement into one new Workspace. A single pane can
            // instead choose whether its fresh copy belongs beside it or apart.
            if window?.selectedWorkspace?.isSplit == true {
                Button("Duplicate", systemImage: MenuSymbol.duplicate) {
                    window?.duplicateSelectedInNewWorkspace()
                }
                .termindShortcut("d")
                .disabled(!(window?.canDuplicateSelected ?? false))
            } else {
                Menu("Duplicate", systemImage: MenuSymbol.duplicate) {
                    Button("in Current Workspace", systemImage: MenuSymbol.currentWorkspace) {
                        window?.duplicateSelected(axis: .horizontal)
                    }
                    .termindShortcut("d")
                    Button("in New Workspace", systemImage: MenuSymbol.newWorkspace) {
                        window?.duplicatePaneInNewWorkspace()
                    }
                    .termindShortcut("d", modifiers: [.command, .shift])
                }
                .disabled(!(window?.canDuplicateSelected ?? false))
            }
        }

        CommandGroup(after: .pasteboard) {
            Button("Generate Command", systemImage: MenuSymbol.generateCommand) {
                app.onboarding.recordUse(of: .commandGenerator)
                window?.generateTerminalCommand(using: app.commandGenerator)
            }
            .termindShortcut("i")
            .disabled(!(window?.canGenerateTerminalCommand ?? false))

            Divider()

            // One Find for the whole window: this focuses the field in the
            // titlebar, whatever that field is currently pointed at. See
            // `WindowModel.findKind`.
            //
            // Find Next and Find Previous below carry no icon of their own: they
            // are the same verb as the item above them, and a menu's icon column
            // reads as a group.
            Button("Find", systemImage: MenuSymbol.find) { window?.focusToolbarFind() }
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
            Button(
                window?.selectedWorkspace?.sourceTemplateID == nil
                    ? "Save Workspace Template" : "Update Workspace Template",
                systemImage: "square.and.arrow.down"
            ) {
                window?.requestSaveWorkspaceTemplate()
            }
            .termindShortcut("s")
            .disabled(!(window?.canSaveSelectedWorkspaceTemplate ?? false))

            Divider()

            // Close Other Workspaces is the same verb one item down, so it goes
            // without an icon of its own.
            Button(closeTitle, systemImage: MenuSymbol.closeWorkspace) {
                guard let window else { return }
                app.mainWindows.closeSelectionOrWindow(in: window)
            }
            .termindShortcut("w")
            .disabled(window == nil)
            Button("Close Window") {
                guard let window else { return }
                app.mainWindows.closeWindow(in: window)
            }
            .termindShortcut("w", modifiers: [.command, .shift])
            .disabled(window == nil)
            Button("Close Other Workspaces") {
                guard let window, let id = window.selectedWorkspaceID else { return }
                window.closeOthers(than: id)
            }
            .termindShortcut("w", modifiers: [.command, .option])
            .disabled(window?.selectedWorkspace == nil)
            Button("Reopen Closed Workspace", systemImage: MenuSymbol.reopenWorkspace) {
                window?.reopenLastClosed()
            }
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
            Button("Show Assistant in Sidebar", systemImage: MenuSymbol.showAssistant) {
                guard let window else { return }
                withAnimation(Motion.panel(reduceMotion: reduceMotion)) {
                    window.showAssistant()
                }
            }
            .termindShortcut("i", modifiers: [.command, .option])
            .disabled(window?.selectedWorkspace == nil)

            Divider()

            // ⌥ still marks the pair that only rearranges the window, against
            // Duplicate's ⌘D, which opens a connection. The keys are the
            // directions themselves rather than ⌥⌘D: macOS owns that one for
            // Turn Dock Hiding On/Off, so pressing it here only hid the Dock.
            Button("Split Right", systemImage: MenuSymbol.splitRight) {
                window?.splitSelected(axis: .horizontal)
            }
            .termindShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(!(window?.canSplitSelected ?? false))
            Button("Split Down", systemImage: MenuSymbol.splitDown) {
                window?.splitSelected(axis: .vertical)
            }
            .termindShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(!(window?.canSplitSelected ?? false))
        }

        CommandGroup(before: .windowList) {
            Button("Move Workspace to New Window", systemImage: MenuSymbol.moveToNewWindow) {
                guard let window, let id = window.selectedWorkspaceID else { return }
                app.mainWindows.moveWorkspace(id, from: window)
            }
            .disabled(window?.selectedWorkspace == nil)

            Divider()

            // One pair, not two. There used to be a ⌃⇥ copy of these beside
            // them, which AppKit's automatic window tabbing already claims for
            // Show Next Tab — so the app's copy was both shadowed and a second
            // name for what ⇧⌘] does. ⇧⌘] is what Safari, Terminal and Finder
            // use, so it is the pair that stays.
            Button("Next Workspace", systemImage: MenuSymbol.nextWorkspace) {
                window?.selectNext()
            }
            .termindShortcut("]", modifiers: [.command, .shift])
            .disabled(window?.workspaces.isEmpty != false)
            Button("Previous Workspace", systemImage: MenuSymbol.previousWorkspace) {
                window?.selectPrevious()
            }
            .termindShortcut("[", modifiers: [.command, .shift])
            .disabled(window?.workspaces.isEmpty != false)

            Divider()

            // ⌘1…⌘8 by sidebar position, ⌘9 to the last Workspace — the convention every
            // browser and terminal shares.
            //
            // One glyph for the whole run, the way Safari lists its tabs, and the
            // same one the Navigator draws beside a merged Workspace. Giving each
            // entry the symbol of what it holds would be readable one line at a
            // time and noise read down the column.
            ForEach(1...8, id: \.self) { index in
                Button("Workspace \(index)", systemImage: MenuSymbol.workspace) {
                    window?.select(index: index - 1)
                }
                .termindShortcut(AppShortcutKey.character(Character("\(index)")))
                .disabled((window?.workspaces.count ?? 0) < index)
            }
            Button("Last Workspace", systemImage: MenuSymbol.workspace) {
                guard let window else { return }
                window.select(index: window.workspaces.count - 1)
            }
            .termindShortcut("9")
            .disabled(window?.workspaces.isEmpty != false)

            Divider()
        }

        CommandGroup(replacing: .help) {
            Link(destination: URL(string: "https://termind.akinokaede.com/support/")!) {
                Label("Support", systemImage: MenuSymbol.support)
            }
        }
    }
}
