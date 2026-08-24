import SwiftUI

/// The first, pinned top-level tab. All durable connection assets live behind
/// its own navigation column so SSH/SFTP Workspaces do not carry app navigation.
struct VaultView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @AppStorage(SettingsKey.compactSidebar) private var compactSidebar = false
    @AppStorage(SettingsKey.showRecents) private var showRecents = true

    var body: some View {
        NavigationSplitView {
            List {
                Section("Vault") {
                    row(.welcome)
                    row(.hosts, count: app.hostLibrary.hosts.count)
                    row(.keychain, count: app.hosts.keys.count + app.hosts.identities.count)
                    row(.snippets, count: app.hosts.snippets.count)
                }

                if showRecents, !recentHosts.isEmpty {
                    Section("Recents") {
                        ForEach(recentHosts) { host in
                            recentRow(host)
                        }
                    }
                }

            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(
                min: Metrics.Sidebar.min,
                ideal: Metrics.Sidebar.ideal,
                max: Metrics.Sidebar.max
            )
        } detail: {
            destination
                .frame(
                    minWidth: Metrics.Window.detailMin,
                    maxWidth: .infinity,
                    minHeight: Metrics.Window.minHeight,
                    maxHeight: .infinity
                )
        }
    }

    private func row(_ page: VaultPage, count: Int = 0) -> some View {
        Button {
            window.openPage(page)
        } label: {
            HStack(spacing: Metrics.Space.s) {
                Label(page.label, systemImage: page.symbol)
                Spacer(minLength: Metrics.Space.xs)
                if count > 0 {
                    Text(count, format: .number)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            window.vaultDestination.page == page
                ? Color.accentColor.opacity(0.16)
                : Color.clear
        )
    }

    private var recentHosts: [Host] {
        app.hosts.recents(limit: 5)
    }

    /// Recents are actions rather than Vault destinations: activating one opens
    /// a full-width SSH Workspace while Vault remains the home for host data.
    private func recentRow(_ host: Host) -> some View {
        Button {
            app.open(host, as: .sshSession, in: window)
        } label: {
            HStack(spacing: Metrics.Space.s) {
                StatusDot(status: app.hosts.status(of: host.id))
                VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                    Text(host.name)
                        .lineLimit(1)
                    if !compactSidebar {
                        Text(app.hosts.loginAddress(for: host))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            HostContextMenu(host: host)
        }
        .help(Text("Quick Connect to \(app.hosts.loginAddress(for: host))"))
        .accessibilityHint("Quick Connect with SSH")
    }

    @ViewBuilder
    private var destination: some View {
        switch window.vaultDestination {
        case .welcome: WelcomeView()
        case .hosts: HostsPageView()
        case .keychain: KeychainPageView()
        case .snippets: SnippetsPageView()
        case .hostEditor(let hostID): HostEditorView(hostID: hostID)
        }
    }
}
