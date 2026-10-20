// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindDomain
import TermindPresentation

private struct MobileSceneFocusedValueKey: FocusedValueKey {
    typealias Value = MobileSceneModel
}

extension FocusedValues {
    var mobileScene: MobileSceneModel? {
        get { self[MobileSceneFocusedValueKey.self] }
        set { self[MobileSceneFocusedValueKey.self] = newValue }
    }
}

nonisolated enum MobileShortcut {
    static let settings = KeyboardShortcut(",", modifiers: .command)
    static let newWindow = KeyboardShortcut("n", modifiers: .command)
    static let connect = KeyboardShortcut("t", modifiers: .command)
    static let batchStartup = KeyboardShortcut("b", modifiers: [.command, .shift])
    static let newChat = KeyboardShortcut("t", modifiers: [.command, .option])
    static let newHost = KeyboardShortcut("n", modifiers: [.command, .shift])
    static let generateCommand = KeyboardShortcut("i", modifiers: .command)
    static let showHistory = KeyboardShortcut("y", modifiers: .command)
    static let showAssistant = KeyboardShortcut("i", modifiers: [.command, .option])
    static let find = KeyboardShortcut("f", modifiers: .command)
    static let findNext = KeyboardShortcut("g", modifiers: .command)
    static let findPrevious = KeyboardShortcut("g", modifiers: [.command, .shift])
    static let reopenWorkspace = KeyboardShortcut("t", modifiers: [.command, .shift])
    static let nextWorkspace = KeyboardShortcut("]", modifiers: [.command, .shift])
    static let previousWorkspace = KeyboardShortcut("[", modifiers: [.command, .shift])
    static let send = KeyboardShortcut(.return, modifiers: .command)
    static let stop = KeyboardShortcut(".", modifiers: .command)
    static let formDefault = KeyboardShortcut(.return, modifiers: [])
    static let formCancel = KeyboardShortcut(.escape, modifiers: [])

    static func workspace(_ index: Int) -> KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
    }
}

/// Scene commands mirror the macOS key map while targeting only the frontmost
/// iOS/iPadOS scene through `FocusedValues.mobileScene`.
struct MobileCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @FocusedValue(\.mobileScene) private var scene

    private var closeShortcuts: WindowCloseShortcuts {
        WindowCloseShortcuts(hasWorkspace: scene?.canCloseWorkspace == true)
    }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(AppStrings.Navigation.settings.swiftUIKey, systemImage: "gearshape") { scene?.openSettings() }
                .keyboardShortcut(MobileShortcut.settings)
                .disabled(scene == nil)
        }

        // iPad's File menu flattens Divider/Section inside replaced command groups. Separate replacement
        // placements preserve the three File sections; groups beside a replaced placement are discarded.
        CommandGroup(replacing: .newItem) {
            Button(AppStrings.Workspace.newWindow.swiftUIKey, systemImage: "macwindow.badge.plus") {
                openWindow(id: TermindIOSApp.mainWindowID)
            }
            .keyboardShortcut(MobileShortcut.newWindow)
            .disabled(!supportsMultipleWindows)
        }

        CommandGroup(replacing: .saveItem) {
            Button(AppStrings.Common.connect.swiftUIKey, systemImage: "network") { scene?.openConnectionPicker() }
                .keyboardShortcut(MobileShortcut.connect)
                .disabled(scene == nil)
            Button(AppStrings.Vault.batchStartup.swiftUIKey, systemImage: "wind") { scene?.openBatchStartup() }
                .keyboardShortcut(MobileShortcut.batchStartup)
                .disabled(scene == nil)
            Button(AppStrings.Assistant.newChat.swiftUIKey, systemImage: "plus.bubble") {
                scene?.openNewConversation()
            }
            .keyboardShortcut(MobileShortcut.newChat)
            .disabled(scene == nil)
            Button(AppStrings.Vault.newHost.swiftUIKey, systemImage: "server.rack") { scene?.openNewHost() }
                .keyboardShortcut(MobileShortcut.newHost)
                .disabled(scene == nil)
        }

        CommandGroup(after: .pasteboard) {
            Button(AppStrings.Workspace.generateCommand.swiftUIKey, systemImage: "sparkles") {
                scene?.generateTerminalCommand()
            }
            .keyboardShortcut(MobileShortcut.generateCommand)
            .disabled(scene?.canUseTerminalCommands != true)

            Divider()

            Button(AppStrings.Workspace.find.swiftUIKey, systemImage: "magnifyingglass") {
                scene?.presentTerminalFind()
            }
            .keyboardShortcut(MobileShortcut.find)
            .disabled(scene?.canUseTerminalCommands != true)
            Button(AppStrings.Terminal.findNextInTerminal.swiftUIKey) { scene?.navigateTerminalFind(.previous) }
                .keyboardShortcut(MobileShortcut.findNext)
                .disabled(scene?.canUseTerminalCommands != true)
            Button(AppStrings.Terminal.findPreviousInTerminal.swiftUIKey) { scene?.navigateTerminalFind(.next) }
                .keyboardShortcut(MobileShortcut.findPrevious)
                .disabled(scene?.canUseTerminalCommands != true)
        }

        CommandGroup(replacing: .importExport) {
            Button(AppStrings.Workspace.closeWindow.swiftUIKey, systemImage: "xmark") {
                scene?.closeWindow()
            }
            .keyboardShortcut(closeShortcuts.closeWindow)
            .disabled(scene == nil)
            Button(AppStrings.Workspace.closeAllWindows.swiftUIKey) { scene?.closeAllWindows() }
                .keyboardShortcut(closeShortcuts.closeAllWindows)
                .disabled(scene == nil)
            Button(AppStrings.Workspace.closeWorkspace.swiftUIKey) { scene?.closeActiveWorkspace() }
                .keyboardShortcut(closeShortcuts.closeWorkspace)
                .disabled(scene?.canCloseWorkspace != true)

        }

        CommandGroup(after: .sidebar) {
            Button(AppStrings.Assistant.showAssistant.swiftUIKey, systemImage: "sparkles") { scene?.showAssistant() }
                .keyboardShortcut(MobileShortcut.showAssistant)
                .disabled(scene == nil)
        }

        CommandMenu(AppStrings.Common.history) {
            Button(AppStrings.History.showHistory.swiftUIKey, systemImage: "clock.arrow.circlepath") {
                scene?.showConnectionHistory()
            }
            .keyboardShortcut(MobileShortcut.showHistory)
            .disabled(scene == nil)

            Divider()

            Menu {
                ForEach(scene?.workspaceSession.recentlyClosedRecords ?? []) { record in
                    if record.isWindow {
                        Menu {
                            Button(AppStrings.History.reopenWindow.swiftUIKey, systemImage: "macwindow") {
                                scene?.workspaceSession.requestClosedWindow(record.id)
                            }
                            Divider()
                            ForEach(record.items) { item in
                                Button {
                                    guard let scene,
                                        let id = scene.workspaceSession.reopenClosedItem(item.id, in: record.id)
                                    else { return }
                                    scene.selectWorkspace(id)
                                } label: {
                                    Label {
                                        Text(verbatim: item.title)
                                    } icon: {
                                        Image(
                                            uiImage: MobileHistoryMenuConfiguration.recordImage(
                                                systemName: item.kind.symbol))
                                    }
                                }
                            }
                        } label: {
                            Label {
                                Text(
                                    AppStrings.History.closedWindow(
                                        record.items.first?.title ?? "", count: record.items.count)
                                )
                            } icon: {
                                Image(
                                    uiImage: MobileHistoryMenuConfiguration.recordImage(
                                        systemName: record.items.first?.kind.symbol ?? "macwindow"))
                            }
                        }
                    } else if let descriptor = record.items.first {
                        Button {
                            scene?.reopenClosedWorkspace(record.id)
                        } label: {
                            Label {
                                Text(verbatim: descriptor.title)
                            } icon: {
                                Image(
                                    uiImage: MobileHistoryMenuConfiguration.recordImage(
                                        systemName: descriptor.kind.symbol))
                            }
                        }
                    }
                }
            } label: {
                HistoryMenuLabel(AppStrings.History.recentClosed, symbol: "clock.arrow.circlepath")
            }
            .disabled(scene?.workspaceSession.canReopen != true)

            Button {
                scene?.reopenLastClosedWorkspace()
            } label: {
                HistoryMenuLabel(
                    scene?.workspaceSession.reopensWindow == true
                        ? AppStrings.Workspace.reopenClosedWindow : AppStrings.Workspace.reopenClosedWorkspace,
                    symbol: "arrow.uturn.backward")
            }
            .keyboardShortcut(MobileShortcut.reopenWorkspace)
            .disabled(scene?.workspaceSession.canReopen != true)

            if let scene {
                HistoryMenuRecords(
                    snapshot: scene.historyMenuSnapshot,
                    image: { Image(uiImage: MobileHistoryMenuConfiguration.recordImage(systemName: $0)) }
                ) { row in
                    scene.open(hostID: row.host.id, kind: row.entry.kind)
                }
            }

            Divider()

            Button {
                scene?.confirmsClearConnectionHistory = true
            } label: {
                HistoryMenuLabel(AppStrings.Common.clearHistory, symbol: "clock.badge.xmark")
            }
            .disabled(scene?.hasConnectionHistory != true)
        }

        CommandGroup(after: .windowArrangement) {
            Button(AppStrings.Workspace.nextWorkspace.swiftUIKey, systemImage: "chevron.forward") {
                scene?.selectNextWorkspace()
            }
            .keyboardShortcut(MobileShortcut.nextWorkspace)
            .disabled(scene?.hasWorkspaces != true)
            Button(AppStrings.Workspace.previousWorkspace.swiftUIKey, systemImage: "chevron.backward") {
                scene?.selectPreviousWorkspace()
            }
            .keyboardShortcut(MobileShortcut.previousWorkspace)
            .disabled(scene?.hasWorkspaces != true)

        }
    }
}
