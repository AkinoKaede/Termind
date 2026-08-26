import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

/// Everything you can do to a host, in one menu.
///
/// Shared by Vault host surfaces, the Welcome page, and the tab bar's
/// recent-hosts menu — places that would otherwise drift into slightly
/// different sets of verbs.
struct HostContextMenu: View {
    let hosts: [Host]
    let showsDuplicate: Bool
    var selectionDeleted: (() -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    init(host: Host, showsDuplicate: Bool = true) {
        hosts = [host]
        self.showsDuplicate = showsDuplicate
        selectionDeleted = nil
    }

    init(
        hosts: [Host],
        showsDuplicate: Bool = true,
        selectionDeleted: (() -> Void)? = nil
    ) {
        self.hosts = hosts
        self.showsDuplicate = showsDuplicate
        self.selectionDeleted = selectionDeleted
    }

    var body: some View {
        // No "Connect in Split": a Workspace is built by combining tabs that are
        // already open, so connecting never decides a layout for you. Connect,
        // then drag the new tab onto the one you want it beside.
        if hosts.count == 1 {
            Button("Quick Connect") { app.open(hosts, as: .sshSession, in: window) }
        } else {
            Menu("Quick Connect") {
                Button("Separate Tabs") {
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
                    copy.lastUsedAt = nil
                    app.hosts.upsert(copy)
                }
            }
            Button("Copy SSH Command") {
                guard let command = app.hosts.sshCommand(for: host) else { return }
                copyToPasteboard(command)
            }
            .disabled(app.hosts.sshCommand(for: host) == nil)
            .help(
                app.hosts.sshCommand(for: host) == nil
                    ? "SSH commands are unavailable for routes that use a Proxy."
                    : "Copy an OpenSSH command for this route."
            )

            Divider()
        }

        Button("Remove from Recents") {
            for host in hosts { app.hosts.forgetRecent(host.id) }
        }
        .disabled(!hosts.contains { $0.lastUsedAt != nil })
        Button("Delete", role: .destructive) {
            for host in hosts { app.hosts.delete(hostID: host.id) }
            selectionDeleted?()
        }
        .disabled(hosts.isEmpty)
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
