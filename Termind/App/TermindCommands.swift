import SwiftUI

/// The menu bar.
///
/// Every command routes through `@FocusedValue(\.window)` rather than a global,
/// so ⌘T opens a tab in the window you are actually looking at. When no window is
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
        CommandGroup(after: .newItem) {
            Button("Quick Open") { window?.isQuickOpenPresented = true }
                .keyboardShortcut("p")
                .disabled(window == nil)
        }

        CommandGroup(replacing: .newItem) {
            // Both of these act on the host selected on the Hosts page, and fall
            // back to that page when there is none — see `AppModel.newTab`.
            //
            // Ordered by how often they are reached, not alphabetically: a
            // session, then a transfer to the same kind of machine, then a chat
            // that is attached to neither.
            Button("Connect") {
                guard let window else { return }
                app.connect(in: window)
            }
            .keyboardShortcut("t")
            Button("New Chat") { window?.openChat() }
                .keyboardShortcut("t", modifiers: [.command, .option])

            Divider()

            Button("New Host") { window?.openHostEditor(host: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            // A multi-pane selection is already a Workspace, so Duplicate
            // copies that whole arrangement into one new tab. A single pane can
            // instead choose whether its fresh copy belongs beside it or apart.
            if window?.selectedTab?.isSplit == true {
                Button("Duplicate") { window?.duplicateSelectedInNewTab() }
                    .keyboardShortcut("d")
                    .disabled(!(window?.canDuplicateSelected ?? false))
            } else {
                Menu("Duplicate") {
                    Button("In Current Workspace") {
                        window?.duplicateSelected(axis: .horizontal)
                    }
                    .keyboardShortcut("d")
                    Button("In New Tab") { window?.duplicatePaneInNewTab() }
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                }
                .disabled(!(window?.canDuplicateSelected ?? false))
            }
        }

        CommandGroup(after: .pasteboard) {
            Button("Find in Terminal") { window?.presentTerminalFind() }
                .keyboardShortcut("f")
                .disabled(!(window?.canFindInTerminal ?? false))

            Button("Find Next in Terminal") {
                window?.navigateTerminalFind(.next)
            }
            .keyboardShortcut("g")
            .disabled(!(window?.canFindInTerminal ?? false))

            Button("Find Previous in Terminal") {
                window?.navigateTerminalFind(.previous)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(!(window?.canFindInTerminal ?? false))
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { window?.closeSelected() }
                .keyboardShortcut("w")
                .disabled(window?.selectedTab == nil)
            Button("Close Other Tabs") {
                guard let window, let id = window.selectedTabID else { return }
                window.closeOthers(than: id)
            }
            .keyboardShortcut("w", modifiers: [.command, .option])
            .disabled(window?.selectedTab == nil)
            Button("Reopen Closed Tab") { window?.reopenLastClosed() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!(window?.canReopen ?? false))
        }

        // No Session menu. What was in it lives in File (Duplicate),
        // in View (the two Splits), on the pane header (Broadcast Input, which
        // shows its own state right next to the panes it reaches and so does not
        // need a second copy in the menu bar — ⌘B is registered by
        // `TabContentView`), or nowhere yet: Clear Scrollback, Ask AI About
        // Selection and Suggest a Command were disabled placeholders holding
        // shortcuts for P2/P4, and P2 can put them wherever the real commands
        // end up.
        CommandGroup(after: .sidebar) {
            Button("Toggle Context Panel") {
                guard let window else { return }
                withAnimation(Motion.panel(reduceMotion: reduceMotion)) {
                    window.showsContextPanel.toggle()
                }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(window?.selectedTab == nil)

            Divider()

            // No modifier duplicates, ⌥ carves an empty slot — the pair that
            // opens a connection and the pair that only rearranges the window
            // are one key apart, and the ⌥ ones never touch the network.
            Button("Split Right") { window?.splitSelected(axis: .horizontal) }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(!(window?.canSplitSelected ?? false))
            Button("Split Down") { window?.splitSelected(axis: .vertical) }
                .keyboardShortcut("d", modifiers: [.command, .option, .shift])
                .disabled(!(window?.canSplitSelected ?? false))
        }

        CommandGroup(before: .windowList) {
            Button("Next Tab") { window?.selectNext() }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { window?.selectPrevious() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("Show Next Tab") { window?.selectNext() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Show Previous Tab") { window?.selectPrevious() }
                .keyboardShortcut("[", modifiers: [.command, .shift])

            Divider()

            // ⌘1…⌘8 by position, ⌘9 to the last tab — the convention every
            // browser and terminal shares.
            ForEach(1...8, id: \.self) { index in
                Button("Tab \(index)") { window?.select(index: index - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")))
            }
            Button("Last Tab") {
                guard let window else { return }
                window.select(index: window.tabs.count + 1)
            }
            .keyboardShortcut("9")

            Divider()
        }

        CommandGroup(replacing: .help) {
            Link("Termind on GitHub", destination: URL(string: "https://github.com/AkinoKaede/vela")!)
        }
    }
}
