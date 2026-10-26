// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
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
    @AppStorage(DesktopSettingsKey.showStatusBar) private var showsStatusBar = true
    @AppStorage(DesktopSettingsKey.showTerminalInputArea) private var showsTerminalInputArea = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.window) private var window

    private var closeShortcuts: WindowCloseShortcuts {
        WindowCloseShortcuts(
            hasWorkspace: !app.mainWindows.isTransfersWindowKey && window?.selectedWorkspace != nil)
    }

    var body: some Commands {
        let _ = app.mainWindows.registerWindowCreation { [openWindow] id in
            openWindow(id: "main", value: id)
        }

        CommandGroup(replacing: .appSettings) {
            Button(AppStrings.Navigation.settings.swiftUIKey, systemImage: MenuSymbol.settings) {
                window?.openSettings()
            }
            .termindShortcut(",")
            .disabled(window == nil)
        }

        CommandGroup(replacing: .newItem) {
            Button(
                AppStrings.Workspace.newWindow,
                systemImage: MenuSymbol.newWindow
            ) {
                app.mainWindows.performNewWindowCommand(from: window)
            }
            .termindShortcut("n")

            Divider()

            // Keep Quick Open inside the replacement group. Placing it in a
            // separate group after `.newItem` makes SwiftUI discard it when
            // this replacement is merged into the final File menu, leaving
            // no menu item (and therefore no working Command-P shortcut).
            Button(AppStrings.Navigation.quickOpen.swiftUIKey, systemImage: MenuSymbol.quickOpen) {
                app.onboarding.recordUse(of: .quickOpen)
                window?.isQuickOpenPresented = true
            }
            .termindShortcut("p")
            .disabled(window == nil)

            Divider()

            Button(AppStrings.Common.connect.swiftUIKey, systemImage: MenuSymbol.ssh) {
                guard let window else { return }
                app.connect(in: window)
            }
            .termindShortcut("t")
            Button(AppStrings.Vault.batchStartup.swiftUIKey, systemImage: MenuSymbol.batchStartup) {
                guard let window else { return }
                app.batchStartup(in: window)
            }
            .termindShortcut("b", modifiers: [.command, .shift])
            .disabled(window == nil)
            Button(AppStrings.Assistant.newChat.swiftUIKey, systemImage: MenuSymbol.newChat) {
                window?.openNewAssistantChat()
            }
            .termindShortcut("t", modifiers: [.command, .option])
            Button(AppStrings.Vault.newHost.swiftUIKey, systemImage: MenuSymbol.newHost) {
                window?.openHostEditor(host: nil)
            }
            .termindShortcut("n", modifiers: [.command, .shift])
            Button(AppStrings.LocalNetwork.discovery.swiftUIKey, systemImage: "dot.radiowaves.left.and.right") {
                window?.openVaultWork(.hostEditor(nil, discover: true), on: .hosts)
            }
            .disabled(window == nil)

            Divider()

            // A multi-pane selection is already a Workspace, so Duplicate
            // copies that whole arrangement into one new Workspace. A single pane can
            // instead choose whether its fresh copy belongs beside it or apart.
            if window?.selectedWorkspace?.isSplit == true {
                Button(AppStrings.Common.duplicate.swiftUIKey, systemImage: MenuSymbol.duplicate) {
                    window?.duplicateSelectedInNewWorkspace()
                }
                .termindShortcut("d")
                .disabled(!(window?.canDuplicateSelected ?? false))
            } else {
                Menu(AppStrings.Common.duplicate.swiftUIKey, systemImage: MenuSymbol.duplicate) {
                    Button(
                        AppStrings.Workspace.inCurrentWorkspace.swiftUIKey, systemImage: MenuSymbol.currentWorkspace
                    ) {
                        window?.duplicateSelected(axis: .horizontal)
                    }
                    .termindShortcut("d")
                    Button(AppStrings.Workspace.inNewWorkspace.swiftUIKey, systemImage: MenuSymbol.newWorkspace) {
                        window?.duplicatePaneInNewWorkspace()
                    }
                    .termindShortcut("d", modifiers: [.command, .shift])
                }
                .disabled(!(window?.canDuplicateSelected ?? false))
            }
        }

        CommandGroup(after: .pasteboard) {
            Button(AppStrings.Workspace.generateCommand.swiftUIKey, systemImage: MenuSymbol.generateCommand) {
                if TerminalInputTextView.generateInFocusedEditor(in: NSApp.keyWindow) { return }
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
            Button(AppStrings.Workspace.find.swiftUIKey, systemImage: MenuSymbol.find) { window?.focusToolbarFind() }
                .termindShortcut("f")
                .disabled(!(window?.canFindInMainContent ?? false))

            // `.previous` walks toward older output, which is where the matches
            // are when a search starts at the bottom of the buffer — so it is
            // what "next" means to a reader. Return in the Find field agrees.
            Button(AppStrings.Terminal.findNextInTerminal.swiftUIKey) {
                window?.navigateTerminalFind(.previous)
            }
            .termindShortcut("g")
            .disabled(!(window?.canFindInTerminal ?? false))

            Button(AppStrings.Terminal.findPreviousInTerminal.swiftUIKey) {
                window?.navigateTerminalFind(.next)
            }
            .termindShortcut("g", modifiers: [.command, .shift])
            .disabled(!(window?.canFindInTerminal ?? false))
        }

        CommandGroup(replacing: .saveItem) {
            Button(
                window?.selectedWorkspace?.sourceTemplateID == nil
                    ? AppStrings.Workspace.saveWorkspaceTemplate.swiftUIKey
                    : AppStrings.Workspace.updateWorkspaceTemplate.swiftUIKey,
                systemImage: "square.and.arrow.down"
            ) {
                window?.requestSaveWorkspaceTemplate()
            }
            .termindShortcut("s")
            .disabled(!(window?.canSaveSelectedWorkspaceTemplate ?? false))

            Divider()

            Button(AppStrings.Workspace.closeWindow.swiftUIKey, systemImage: MenuSymbol.closeWorkspace) {
                if app.mainWindows.isTransfersWindowKey {
                    app.mainWindows.closeTransfers()
                    return
                }
                guard let window else { return }
                app.mainWindows.closeWindow(in: window)
            }
            .termindShortcut(closeShortcuts.closeWindow)
            .disabled(window == nil && !app.mainWindows.isTransfersWindowKey)
            Button(AppStrings.Workspace.closeAllWindows.swiftUIKey) {
                app.mainWindows.closeAllWindows()
            }
            .termindShortcut(closeShortcuts.closeAllWindows)
            .disabled(window == nil)
            Button(AppStrings.Workspace.closeWorkspace.swiftUIKey) {
                guard !app.mainWindows.isTransfersWindowKey else { return }
                window?.closeSelected()
            }
            .termindShortcut(closeShortcuts.closeWorkspace)
            .disabled(app.mainWindows.isTransfersWindowKey || window?.selectedWorkspace == nil)

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
            Button(AppStrings.Assistant.showAssistant.swiftUIKey, systemImage: MenuSymbol.showAssistant) {
                guard let window else { return }
                withAnimation(Motion.panel(reduceMotion: reduceMotion)) {
                    window.showAssistant()
                }
            }
            .termindShortcut("i", modifiers: [.command, .option])
            .disabled(window == nil)

            Button(
                (showsStatusBar ? AppStrings.Settings.hideStatusBar : AppStrings.Settings.showStatusBar).swiftUIKey
            ) {
                showsStatusBar.toggle()
            }

            Button(
                (showsTerminalInputArea ? AppStrings.TerminalInput.hide : AppStrings.TerminalInput.show).swiftUIKey
            ) {
                showsTerminalInputArea.toggle()
            }

            Button(
                (app.mainWindows.isTransfersWindowOpen
                    ? AppStrings.SFTP.closeTransfers : AppStrings.SFTP.openTransfers).swiftUIKey,
                systemImage: "arrow.up.arrow.down"
            ) {
                app.mainWindows.toggleTransfers()
            }

            Divider()

            // ⌥ still marks the pair that only rearranges the window, against
            // Duplicate's ⌘D, which opens a connection. The keys are the
            // directions themselves rather than ⌥⌘D: macOS owns that one for
            // Turn Dock Hiding On/Off, so pressing it here only hid the Dock.
            Button(AppStrings.Workspace.splitRight.swiftUIKey, systemImage: MenuSymbol.splitRight) {
                window?.splitSelected(axis: .horizontal)
            }
            .termindShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(!(window?.canSplitSelected ?? false))
            Button(AppStrings.Workspace.splitDown.swiftUIKey, systemImage: MenuSymbol.splitDown) {
                window?.splitSelected(axis: .vertical)
            }
            .termindShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(!(window?.canSplitSelected ?? false))
        }

        CommandMenu(AppStrings.Common.history) {
            Button {
                window?.showConnectionHistory()
            } label: {
                Label {
                    Text(AppStrings.History.showHistory)
                } icon: {
                    Image(nsImage: MenuImageVisibilityController.markedImage(systemName: "clock.arrow.circlepath"))
                }
            }
            .termindShortcut("y")
            .disabled(window == nil)

            Divider()

            Menu {
                ForEach(app.closedWorkspaceRecords) { record in
                    if record.isWindow {
                        Menu {
                            Button {
                                app.reopenClosedRecord(record.id, in: window)
                            } label: {
                                HistoryMenuLabel(AppStrings.History.reopenWindow, symbol: "macwindow")
                            }
                            Divider()
                            ForEach(record.items) { item in
                                Button {
                                    guard let window else { return }
                                    app.restoreClosedRecord(record.id, into: window, itemID: item.id)
                                } label: {
                                    Label {
                                        Text(verbatim: item.title)
                                    } icon: {
                                        Image(
                                            nsImage: MenuImageVisibilityController.markedImage(systemName: item.symbol))
                                    }
                                }
                                .disabled(window == nil)
                            }
                        } label: {
                            Label {
                                Text(
                                    AppStrings.History.closedWindow(
                                        record.items.first?.title ?? "", count: record.items.count)
                                )
                            } icon: {
                                Image(
                                    nsImage: MenuImageVisibilityController.markedImage(
                                        systemName: record.items.first?.symbol ?? "macwindow"))
                            }
                        }
                    } else if let item = record.items.first {
                        Button {
                            app.reopenClosedRecord(record.id, in: window)
                        } label: {
                            Label {
                                Text(verbatim: item.title)
                            } icon: {
                                Image(nsImage: MenuImageVisibilityController.markedImage(systemName: item.symbol))
                            }
                        }
                    }
                }
            } label: {
                HistoryMenuLabel(AppStrings.History.recentClosed, symbol: "clock.arrow.circlepath")
            }
            .disabled(app.closedWorkspaceRecords.isEmpty)

            Button {
                if let record = app.closedWorkspaceRecords.first { app.reopenClosedRecord(record.id, in: window) }
            } label: {
                HistoryMenuLabel(
                    app.closedWorkspaceRecords.first?.isWindow == true
                        ? AppStrings.Workspace.reopenClosedWindow : AppStrings.Workspace.reopenClosedWorkspace,
                    symbol: MenuSymbol.reopenWorkspace)
            }
            .termindShortcut("t", modifiers: [.command, .shift])
            .disabled(app.closedWorkspaceRecords.isEmpty)

            HistoryMenuRecords(
                snapshot: ConnectionHistoryMenuSnapshot(
                    history: app.connectionHistory, library: app.hostLibrary),
                image: { Image(nsImage: MenuImageVisibilityController.markedImage(systemName: $0)) }
            ) { row in
                guard let window, let host = app.hostLibrary.host(row.host.id) else { return }
                let target: HostOpenTarget =
                    switch row.entry.kind {
                    case .ssh: .sshSession
                    case .mosh: .moshSession
                    case .eternalTerminal: .eternalTerminalSession
                    case .telnet: .telnetSession
                    case .sftp: .sftpChannel
                    }
                app.open(host, as: target, in: window)
            }
            .disabled(window == nil)

            Divider()

            Button {
                window?.confirmsClearConnectionHistory = true
            } label: {
                HistoryMenuLabel(AppStrings.Common.clearHistory, symbol: MenuSymbol.clearHistory)
            }
            .disabled(window == nil || app.connectionHistory.entries().isEmpty)
        }

        CommandGroup(before: .windowList) {
            Button(AppStrings.Workspace.moveWorkspaceToNewWindow.swiftUIKey, systemImage: MenuSymbol.moveToNewWindow) {
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
            Button(AppStrings.Workspace.nextWorkspace.swiftUIKey, systemImage: MenuSymbol.nextWorkspace) {
                window?.selectNext()
            }
            .termindShortcut("]", modifiers: [.command, .shift])
            .disabled(window?.workspaces.isEmpty != false)
            Button(AppStrings.Workspace.previousWorkspace.swiftUIKey, systemImage: MenuSymbol.previousWorkspace) {
                window?.selectPrevious()
            }
            .termindShortcut("[", modifiers: [.command, .shift])
            .disabled(window?.workspaces.isEmpty != false)

            Divider()
        }

        CommandGroup(replacing: .help) {
            Link(destination: URL(string: "https://termind.akinokaede.com/support/")!) {
                Label(AppStrings.Settings.support.swiftUIKey, systemImage: MenuSymbol.support)
            }
        }
    }
}
