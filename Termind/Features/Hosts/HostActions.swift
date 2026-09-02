import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

/// Everything you can do to a host, in one menu.
///
/// Shared by Vault host surfaces, the Welcome page, and the workspace list's
/// recent-hosts menu — places that would otherwise drift into slightly
/// different sets of verbs.
struct HostContextMenu: View {
    let hosts: [Host]
    let showsDuplicate: Bool
    let requestClearAllHistory: ([Host.ID]) -> Void
    var selectionDeleted: (() -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    init(
        host: Host,
        showsDuplicate: Bool = true,
        requestClearAllHistory: @escaping ([Host.ID]) -> Void
    ) {
        hosts = [host]
        self.showsDuplicate = showsDuplicate
        self.requestClearAllHistory = requestClearAllHistory
        selectionDeleted = nil
    }

    init(
        hosts: [Host],
        showsDuplicate: Bool = true,
        selectionDeleted: (() -> Void)? = nil,
        requestClearAllHistory: @escaping ([Host.ID]) -> Void
    ) {
        self.hosts = hosts
        self.showsDuplicate = showsDuplicate
        self.selectionDeleted = selectionDeleted
        self.requestClearAllHistory = requestClearAllHistory
    }

    var body: some View {
        // No "Connect in Split": a Workspace is built by combining workspaces that are
        // already open, so connecting never decides a layout for you. Connect,
        // then drag the new workspace onto the one you want it beside.
        if hosts.count == 1 {
            Button("Quick Connect") { app.open(hosts, as: .sshSession, in: window) }
        } else {
            Menu("Quick Connect") {
                Button("Separate Workspaces") {
                    app.open(hosts, as: .sshSession, in: window)
                }
                Button("One Workspace") {
                    app.open(hosts, as: .sshSession, layout: .oneWorkspace, in: window)
                }
            }
        }
        HostConnectMenu(hosts: hosts)

        Divider()

        if hosts.count == 1, let host = hosts.first {
            Button("Edit") { window.openHostEditor(host: host) }
            if showsDuplicate {
                Button("Duplicate") {
                    var copy = host
                    copy.id = UUID()
                    copy.name = String(localized: "\(host.name) copy")
                    app.hostLibrary.upsert(copy)
                }
            }
            Button("Copy SSH Command") {
                guard let command = app.hostLibrary.sshCommand(for: host) else { return }
                copyToPasteboard(command)
            }
            .disabled(app.hostLibrary.sshCommand(for: host) == nil)
            .help(
                app.hostLibrary.sshCommand(for: host) == nil
                    ? "SSH commands are unavailable for routes that use a Proxy."
                    : "Copy an OpenSSH command for this route."
            )

            Divider()
        }

        DestructiveMenuButton("Clear All History") {
            requestClearAllHistory(hosts.map(\.id))
        }
        .disabled(!hasHistory)
        DestructiveMenuButton("Delete") {
            for host in hosts { app.requestHostDeletion(host.id) }
            selectionDeleted?()
        }
        .disabled(hosts.isEmpty)
    }

    private var hasHistory: Bool {
        hosts.contains { host in
            !app.connectionHistory.entries(for: host.id).isEmpty
                || !app.commandHistory.entries(for: host.id).isEmpty
                || !app.sftpHistory.entries(for: host.id).isEmpty
        }
    }
}

private struct ClearAllHostHistoryConfirmation: ViewModifier {
    @Binding var hostIDs: [Host.ID]?

    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Clear all history for the selected Hosts?",
            isPresented: Binding(
                get: { hostIDs != nil },
                set: { if !$0 { hostIDs = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Clear All History", role: .destructive) {
                guard let hostIDs else { return }
                app.clearAllHistory(for: hostIDs)
                self.hostIDs = nil
            }
            Button("Cancel", role: .cancel) { hostIDs = nil }
        } message: {
            Text(
                "This permanently removes connection, command, and File History without deleting the Hosts."
            )
        }
    }
}

extension View {
    func clearAllHostHistoryConfirmation(hostIDs: Binding<[Host.ID]?>) -> some View {
        modifier(ClearAllHostHistoryConfirmation(hostIDs: hostIDs))
    }
}

/// `HostContextMenu` as native menu entries, for the sidebar rows that draw
/// their own selection outline and so cannot use SwiftUI's `contextMenu`.
///
/// Deliberately in this file, beside the SwiftUI version: these two are one set
/// of verbs and the only thing keeping them from drifting is being read
/// together. Anything added above belongs here too.
@MainActor
enum HostMenuEntries {
    static func entries(
        for host: Host,
        app: AppModel,
        window: WindowModel
    ) -> [NativeMenuEntry] {
        [
            NativeMenuEntry(title: String(localized: "Quick Connect")) {
                app.open([host], as: .sshSession, in: window)
            },
            NativeMenuEntry(
                title: String(localized: "Connect"),
                children: [
                    NativeMenuEntry(title: String(localized: "With SSH")) {
                        app.open([host], as: .sshSession, in: window)
                    },
                    NativeMenuEntry(title: String(localized: "With SFTP")) {
                        app.open([host], as: .sftpSession, in: window)
                    },
                ]
            ),
            .separator,
            NativeMenuEntry(title: String(localized: "Edit")) {
                window.openHostEditor(host: host)
            },
            NativeMenuEntry(
                title: String(localized: "Copy SSH Command"),
                isEnabled: app.hostLibrary.sshCommand(for: host) != nil
            ) {
                guard let command = app.hostLibrary.sshCommand(for: host) else { return }
                copyToPasteboard(command)
            },
        ]
    }
}

struct HostConnectMenu: View {
    let hosts: [Host]

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    var body: some View {
        Menu("Connect") {
            Button("With SSH") { app.open(hosts, as: .sshSession, in: window) }
            Button("With SFTP") { app.open(hosts, as: .sftpSession, in: window) }
        }
    }
}

/// One place that knows about `NSPasteboard`, so the views stay platform-neutral
/// for the eventual iPadOS layout.
@discardableResult
func copyToPasteboard(_ text: String) -> Bool {
    #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    #else
        return false
    #endif
}
