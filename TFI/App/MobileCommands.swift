import SwiftUI
import TermindDomain

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
    static let connect = KeyboardShortcut("t", modifiers: .command)
    static let newChat = KeyboardShortcut("t", modifiers: [.command, .option])
    static let newHost = KeyboardShortcut("n", modifiers: [.command, .shift])
    static let generateCommand = KeyboardShortcut("i", modifiers: .command)
    static let find = KeyboardShortcut("f", modifiers: .command)
    static let findNext = KeyboardShortcut("g", modifiers: .command)
    static let findPrevious = KeyboardShortcut("g", modifiers: [.command, .shift])
    static let closeWorkspace = KeyboardShortcut("w", modifiers: .command)
    static let nextWorkspace = KeyboardShortcut("]", modifiers: [.command, .shift])
    static let previousWorkspace = KeyboardShortcut("[", modifiers: [.command, .shift])
    static let send = KeyboardShortcut(.return, modifiers: .command)
    static let stop = KeyboardShortcut(".", modifiers: .command)

    static func workspace(_ index: Int) -> KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
    }
}

/// Scene commands mirror the macOS key map while targeting only the frontmost
/// iOS/iPadOS scene through `FocusedValues.mobileScene`.
struct MobileCommands: Commands {
    @FocusedValue(\.mobileScene) private var scene

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings", systemImage: "gearshape") { scene?.openSettings() }
                .keyboardShortcut(MobileShortcut.settings)
                .disabled(scene == nil)
        }

        CommandGroup(replacing: .newItem) {
            Button("Connect", systemImage: "network") { scene?.openConnectionPicker() }
                .keyboardShortcut(MobileShortcut.connect)
                .disabled(scene == nil)
            Button("New Chat", systemImage: "plus.bubble") { scene?.openNewConversation() }
                .keyboardShortcut(MobileShortcut.newChat)
                .disabled(scene == nil)
            Button("New Host", systemImage: "server.rack") { scene?.openNewHost() }
                .keyboardShortcut(MobileShortcut.newHost)
                .disabled(scene == nil)
        }

        CommandGroup(after: .pasteboard) {
            Button("Generate Command", systemImage: "sparkles") { scene?.generateTerminalCommand() }
                .keyboardShortcut(MobileShortcut.generateCommand)
                .disabled(scene?.canUseTerminalCommands != true)

            Divider()

            Button("Find", systemImage: "magnifyingglass") { scene?.presentTerminalFind() }
                .keyboardShortcut(MobileShortcut.find)
                .disabled(scene?.canUseTerminalCommands != true)
            Button("Find Next in Terminal") { scene?.navigateTerminalFind(.previous) }
                .keyboardShortcut(MobileShortcut.findNext)
                .disabled(scene?.canUseTerminalCommands != true)
            Button("Find Previous in Terminal") { scene?.navigateTerminalFind(.next) }
                .keyboardShortcut(MobileShortcut.findPrevious)
                .disabled(scene?.canUseTerminalCommands != true)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close Workspace", systemImage: "xmark") { scene?.closeActiveWorkspace() }
                .keyboardShortcut(MobileShortcut.closeWorkspace)
                .disabled(scene?.canCloseWorkspace != true)
        }

        CommandMenu("Workspaces") {
            Button("Next Workspace", systemImage: "chevron.forward") { scene?.selectNextWorkspace() }
                .keyboardShortcut(MobileShortcut.nextWorkspace)
                .disabled(scene?.hasWorkspaces != true)
            Button("Previous Workspace", systemImage: "chevron.backward") { scene?.selectPreviousWorkspace() }
                .keyboardShortcut(MobileShortcut.previousWorkspace)
                .disabled(scene?.hasWorkspaces != true)

            Divider()

            ForEach(1...8, id: \.self) { index in
                Button("Workspace \(index)", systemImage: "terminal") {
                    scene?.selectWorkspace(at: index - 1)
                }
                .keyboardShortcut(MobileShortcut.workspace(index))
                .disabled((scene?.workspaceCount ?? 0) < index)
            }
            Button("Last Workspace", systemImage: "terminal") { scene?.selectLastWorkspace() }
                .keyboardShortcut(MobileShortcut.workspace(9))
                .disabled(scene?.hasWorkspaces != true)
        }
    }
}
