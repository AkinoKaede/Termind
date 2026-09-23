import SwiftUI
import TermindDomain
import TermindPresentation

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

    private var closeTitle: LocalizedStringResource {
        guard let workspace = window?.selectedWorkspace else { return TermindCopy.Workspace.closeWindow }
        return workspace.isSplit ? TermindCopy.Workspace.closePaneAction : TermindCopy.Workspace.closeWorkspace
    }

    private var newWindowConnects: Bool { app.mainWindows.isFullScreen(window) }
    private var newWindowTitle: LocalizedStringResource {
        newWindowConnects ? TermindCopy.Common.connect : TermindCopy.Workspace.newWindow
    }

    var body: some Commands {
        let _ = app.mainWindows.registerWindowCreation { [openWindow] id in
            openWindow(id: "main", value: id)
        }

        CommandGroup(replacing: .appSettings) {
            Button(TermindCopy.Navigation.settings.swiftUIKey, systemImage: MenuSymbol.settings) {
                window?.openSettings()
            }
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
            Button(TermindCopy.Navigation.quickOpen.swiftUIKey, systemImage: MenuSymbol.quickOpen) {
                app.onboarding.recordUse(of: .quickOpen)
                window?.isQuickOpenPresented = true
            }
            .termindShortcut("p")
            .disabled(window == nil)

            Divider()

            Button(TermindCopy.Common.connect.swiftUIKey, systemImage: MenuSymbol.ssh) {
                guard let window else { return }
                app.connect(in: window)
            }
            .termindShortcut("t")
            Button(TermindCopy.Vault.batchStartup.swiftUIKey, systemImage: MenuSymbol.batchStartup) {
                guard let window else { return }
                app.batchStartup(in: window)
            }
            .termindShortcut("b", modifiers: [.command, .shift])
            .disabled(window == nil)
            Button(TermindCopy.Assistant.newChat.swiftUIKey, systemImage: MenuSymbol.newChat) {
                window?.openNewAssistantChat()
            }
            .termindShortcut("t", modifiers: [.command, .option])
            Button(TermindCopy.Vault.newHost.swiftUIKey, systemImage: MenuSymbol.newHost) {
                window?.openHostEditor(host: nil)
            }
            .termindShortcut("n", modifiers: [.command, .shift])

            Divider()

            // A multi-pane selection is already a Workspace, so Duplicate
            // copies that whole arrangement into one new Workspace. A single pane can
            // instead choose whether its fresh copy belongs beside it or apart.
            if window?.selectedWorkspace?.isSplit == true {
                Button(TermindCopy.Common.duplicate.swiftUIKey, systemImage: MenuSymbol.duplicate) {
                    window?.duplicateSelectedInNewWorkspace()
                }
                .termindShortcut("d")
                .disabled(!(window?.canDuplicateSelected ?? false))
            } else {
                Menu(TermindCopy.Common.duplicate.swiftUIKey, systemImage: MenuSymbol.duplicate) {
                    Button(
                        TermindCopy.Workspace.inCurrentWorkspace.swiftUIKey, systemImage: MenuSymbol.currentWorkspace
                    ) {
                        window?.duplicateSelected(axis: .horizontal)
                    }
                    .termindShortcut("d")
                    Button(TermindCopy.Workspace.inNewWorkspace.swiftUIKey, systemImage: MenuSymbol.newWorkspace) {
                        window?.duplicatePaneInNewWorkspace()
                    }
                    .termindShortcut("d", modifiers: [.command, .shift])
                }
                .disabled(!(window?.canDuplicateSelected ?? false))
            }
        }

        CommandGroup(after: .pasteboard) {
            Button(TermindCopy.Workspace.generateCommand.swiftUIKey, systemImage: MenuSymbol.generateCommand) {
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
            Button(TermindCopy.Workspace.find.swiftUIKey, systemImage: MenuSymbol.find) { window?.focusToolbarFind() }
                .termindShortcut("f")
                .disabled(!(window?.canFindInMainContent ?? false))

            // `.previous` walks toward older output, which is where the matches
            // are when a search starts at the bottom of the buffer — so it is
            // what "next" means to a reader. Return in the Find field agrees.
            Button(TermindCopy.Terminal.findNextInTerminal.swiftUIKey) {
                window?.navigateTerminalFind(.previous)
            }
            .termindShortcut("g")
            .disabled(!(window?.canFindInTerminal ?? false))

            Button(TermindCopy.Terminal.findPreviousInTerminal.swiftUIKey) {
                window?.navigateTerminalFind(.next)
            }
            .termindShortcut("g", modifiers: [.command, .shift])
            .disabled(!(window?.canFindInTerminal ?? false))
        }

        CommandGroup(replacing: .saveItem) {
            Button(
                window?.selectedWorkspace?.sourceTemplateID == nil
                    ? TermindCopy.Workspace.saveWorkspaceTemplate.swiftUIKey
                    : TermindCopy.Workspace.updateWorkspaceTemplate.swiftUIKey,
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
            Button(TermindCopy.Workspace.closeWindow.swiftUIKey) {
                guard let window else { return }
                app.mainWindows.closeWindow(in: window)
            }
            .termindShortcut("w", modifiers: [.command, .shift])
            .disabled(window == nil)
            Button(TermindCopy.Workspace.closeOtherWorkspaces.swiftUIKey) {
                guard let window, let id = window.selectedWorkspaceID else { return }
                window.closeOthers(than: id)
            }
            .termindShortcut("w", modifiers: [.command, .option])
            .disabled(window?.selectedWorkspace == nil)
            Button(TermindCopy.Workspace.reopenClosedWorkspace.swiftUIKey, systemImage: MenuSymbol.reopenWorkspace) {
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
            Button(TermindCopy.Assistant.showAssistantInSidebar.swiftUIKey, systemImage: MenuSymbol.showAssistant) {
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
            Button(TermindCopy.Workspace.splitRight.swiftUIKey, systemImage: MenuSymbol.splitRight) {
                window?.splitSelected(axis: .horizontal)
            }
            .termindShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(!(window?.canSplitSelected ?? false))
            Button(TermindCopy.Workspace.splitDown.swiftUIKey, systemImage: MenuSymbol.splitDown) {
                window?.splitSelected(axis: .vertical)
            }
            .termindShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(!(window?.canSplitSelected ?? false))
        }

        CommandGroup(before: .windowList) {
            Button(TermindCopy.Workspace.moveWorkspaceToNewWindow.swiftUIKey, systemImage: MenuSymbol.moveToNewWindow) {
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
            Button(TermindCopy.Workspace.nextWorkspace.swiftUIKey, systemImage: MenuSymbol.nextWorkspace) {
                window?.selectNext()
            }
            .termindShortcut("]", modifiers: [.command, .shift])
            .disabled(window?.workspaces.isEmpty != false)
            Button(TermindCopy.Workspace.previousWorkspace.swiftUIKey, systemImage: MenuSymbol.previousWorkspace) {
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
                Button(TermindCopy.Workspace.numberedWorkspace(index).swiftUIKey, systemImage: MenuSymbol.workspace) {
                    window?.select(index: index - 1)
                }
                .termindShortcut(AppShortcutKey.character(Character("\(index)")))
                .disabled((window?.workspaces.count ?? 0) < index)
            }
            Button(TermindCopy.Workspace.lastWorkspace.swiftUIKey, systemImage: MenuSymbol.workspace) {
                guard let window else { return }
                window.select(index: window.workspaces.count - 1)
            }
            .termindShortcut("9")
            .disabled(window?.workspaces.isEmpty != false)

            Divider()
        }

        CommandGroup(replacing: .help) {
            Link(destination: URL(string: "https://termind.akinokaede.com/support/")!) {
                Label(TermindCopy.Settings.support.swiftUIKey, systemImage: MenuSymbol.support)
            }
        }
    }
}
