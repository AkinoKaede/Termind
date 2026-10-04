import SwiftUI
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

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
    let requestDelete: (() -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    init(
        host: Host,
        showsDuplicate: Bool = true,
        requestDelete: (() -> Void)? = nil
    ) {
        hosts = [host]
        self.showsDuplicate = showsDuplicate
        self.requestDelete = requestDelete
    }

    init(
        hosts: [Host],
        showsDuplicate: Bool = true,
        requestDelete: @escaping () -> Void
    ) {
        self.hosts = hosts
        self.showsDuplicate = showsDuplicate
        self.requestDelete = requestDelete
    }

    var body: some View {
        // No "Connect in Split": a Workspace is built by combining workspaces that are
        // already open, so connecting never decides a layout for you. Connect,
        // then drag the new workspace onto the one you want it beside.
        Button(AppStrings.Vault.quickConnect.swiftUIKey, systemImage: MenuSymbol.quickConnect) {
            app.open(
                hosts,
                as: .preferredTerminal,
                layout: HostMenuPolicy.quickConnectLayout(for: hosts),
                in: window
            )
        }
        HostConnectMenu(hosts: hosts)

        if hosts.count == 1, let host = hosts.first {
            copySSHCommandButton(host)
        }

        Divider()

        if hosts.count == 1, let host = hosts.first {
            if host.isTailscaleManaged || app.tailscale.peer(for: host) != nil {
                Button(AppStrings.Tailscale.title.swiftUIKey, systemImage: "point.3.connected.trianglepath.dotted") {
                    window.openVaultWork(.tailscaleDetails(host.id), on: .hosts)
                }
                Divider()
            }
            Button(AppStrings.Common.edit.swiftUIKey, systemImage: MenuSymbol.edit) {
                window.openHostEditor(host: host)
            }
            if showsDuplicate {
                Button(AppStrings.Common.duplicate.swiftUIKey, systemImage: MenuSymbol.duplicate) {
                    HostMenuEntries.duplicate(host, in: app)
                }
                .disabled(host.isTailscaleManaged)
            }
            Divider()
        }

        if let requestDelete {
            DestructiveMenuButton(AppStrings.Common.delete) {
                requestDelete()
            }
            .disabled(hosts.isEmpty || hosts.contains(where: \.isTailscaleManaged))
        }
    }

    @ViewBuilder
    private func copySSHCommandButton(_ host: Host) -> some View {
        Button(AppStrings.Vault.copySshCommand.swiftUIKey, systemImage: MenuSymbol.copy) {
            guard let command = app.hostLibrary.sshCommand(for: host) else { return }
            copyToPasteboard(command)
        }
        .disabled(app.hostLibrary.sshCommand(for: host) == nil)
        .help(
            app.hostLibrary.sshCommand(for: host) == nil
                ? AppStrings.Vault.sshCommandsAreUnavailableForRoutesThatUseAProxy.swiftUIKey
                : AppStrings.Vault.copyAnOpenSSHCommandForThisRoute.swiftUIKey
        )
    }
}

enum HostMenuPolicy {
    static func quickConnectLayout(for hosts: [Host]) -> BatchLayout {
        hosts.count > 1 ? .oneWorkspace : .separateWorkspaces
    }
}

enum HostConnectAction: CaseIterable, Hashable {
    case ssh
    case telnet
    case sftp

    static func available(for hosts: [Host]) -> [Self] {
        allCases.filter { action in hosts.contains(where: action.supports) }
    }

    func matchingHosts(in hosts: [Host]) -> [Host] {
        hosts.filter(supports)
    }

    var target: HostOpenTarget {
        switch self {
        case .ssh: .sshSession
        case .telnet: .telnetSession
        case .sftp: .sftpChannel
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .ssh: AppStrings.Vault.withSsh
        case .telnet: AppStrings.Vault.withTelnet
        case .sftp: AppStrings.Vault.withSftp
        }
    }

    var symbol: String {
        switch self {
        case .ssh: MenuSymbol.ssh
        case .telnet: MenuSymbol.telnet
        case .sftp: MenuSymbol.sftp
        }
    }

    private func supports(_ host: Host) -> Bool {
        switch self {
        case .ssh, .sftp: host.sshEnabled
        case .telnet: host.telnetEnabled
        }
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
        window: WindowModel,
        includesCopySSHCommand: Bool = true,
        includesDuplicate: Bool = false
    ) -> [NativeMenuEntry] {
        let connectActions = HostConnectAction.available(for: [host])
        var entries = [
            NativeMenuEntry(
                title: AppStrings.Vault.quickConnect, symbol: MenuSymbol.quickConnect
            ) {
                app.open([host], as: .preferredTerminal, in: window)
            }
        ]
        if !connectActions.isEmpty {
            entries.append(
                NativeMenuEntry(
                    title: AppStrings.Common.connect,
                    symbol: MenuSymbol.connect,
                    children: connectActions.map { action in
                        NativeMenuEntry(
                            title: action.title, symbol: action.symbol
                        ) {
                            app.open(action.matchingHosts(in: [host]), as: action.target, in: window)
                        }
                    }
                ))
        }
        if includesCopySSHCommand {
            entries.append(
                NativeMenuEntry(
                    title: AppStrings.Vault.copySshCommand,
                    symbol: MenuSymbol.copy,
                    isEnabled: app.hostLibrary.sshCommand(for: host) != nil
                ) {
                    guard let command = app.hostLibrary.sshCommand(for: host) else { return }
                    copyToPasteboard(command)
                })
        }
        entries.append(.separator)
        if host.isTailscaleManaged || app.tailscale.peer(for: host) != nil {
            entries.append(
                NativeMenuEntry(title: AppStrings.Tailscale.title, symbol: "point.3.connected.trianglepath.dotted") {
                    window.openVaultWork(.tailscaleDetails(host.id), on: .hosts)
                })
            entries.append(.separator)
        }
        entries.append(
            NativeMenuEntry(title: AppStrings.Common.edit, symbol: MenuSymbol.edit) {
                window.openHostEditor(host: host)
            })
        if includesDuplicate {
            entries.append(
                NativeMenuEntry(
                    title: AppStrings.Common.duplicate, symbol: MenuSymbol.duplicate,
                    isEnabled: !host.isTailscaleManaged
                ) {
                    duplicate(host, in: app)
                })
        }
        return entries
    }

    static func duplicate(_ host: Host, in app: AppModel) {
        var copy = host
        if host.identityID.flatMap(app.hostLibrary.identity)?.isHostCustom == true {
            copy.identityID = nil
        }
        if host.proxy?.identityID.flatMap(app.hostLibrary.identity)?.isHostCustom == true {
            copy.proxy?.identityID = nil
            copy.proxy?.username = ""
        }
        if host.telnetIdentityID.flatMap(app.hostLibrary.identity)?.isHostCustom == true {
            copy.telnetIdentityID = nil
        }
        if host.telnetProxy?.identityID.flatMap(app.hostLibrary.identity)?.isHostCustom == true {
            copy.telnetProxy?.identityID = nil
            copy.telnetProxy?.username = ""
        }
        copy.id = UUID()
        copy.name = String(localized: AppStrings.Vault.duplicatedHostName(host.name))
        app.hostLibrary.upsert(copy)
    }
}

struct HostConnectMenu: View {
    let hosts: [Host]

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    var body: some View {
        let actions = HostConnectAction.available(for: hosts)
        if !actions.isEmpty {
            Menu(AppStrings.Common.connect.swiftUIKey, systemImage: MenuSymbol.connect) {
                ForEach(actions, id: \.self) { action in
                    Button {
                        app.open(action.matchingHosts(in: hosts), as: action.target, in: window)
                    } label: {
                        Label {
                            Text(action.title)
                        } icon: {
                            Image(systemName: action.symbol)
                        }
                    }
                }
            }
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
