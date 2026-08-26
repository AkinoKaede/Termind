import SwiftUI

/// Vault's navigation mode inside the window's one shared sidebar.
struct VaultSidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @AppStorage(SettingsKey.compactSidebar) private var compactSidebar = false
    @AppStorage(SettingsKey.showRecents) private var showRecents = true
    @State private var hoveredPage: VaultPage?
    @State private var hoveredRecentHostID: Host.ID?

    var body: some View {
        List {
            row(.welcome)

            Section("Vault") {
                row(.hosts, count: app.hostLibrary.hosts.count)
                row(.keychain, count: app.hostLibrary.keys.count + app.hostLibrary.identities.count)
                row(.snippets, count: app.hostLibrary.snippets.count)
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
    }

    private func row(_ page: VaultPage, count: Int = 0) -> some View {
        let isSelected = window.vaultDestination.page == page

        return Button {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.Sidebar.navigationRowHeight)
            .padding(.horizontal, Metrics.Sidebar.navigationRowInset)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { setPageHover($0, page: page) }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .listRowBackground(
            rowFill(isSelected: isSelected, isHovering: hoveredPage == page)
        )
        .listRowInsets(EdgeInsets())
    }

    private var recentHosts: [Host] {
        app.hostLibrary.recents(limit: 5)
    }

    /// Recents are actions rather than Vault destinations: activating one opens
    /// a full-width SSH Workspace while Vault remains the home for host data.
    private func recentRow(_ host: Host) -> some View {
        Button {
            app.open(host, as: .sshSession, in: window)
        } label: {
            HStack(spacing: Metrics.Space.s) {
                StatusDot(status: app.hostLibrary.status(of: host.id))
                VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                    Text(host.name)
                        .lineLimit(1)
                    if !compactSidebar {
                        Text(app.hostLibrary.loginAddress(for: host))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: Metrics.Sidebar.navigationRowHeight)
            .padding(.horizontal, Metrics.Sidebar.navigationRowInset)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { setRecentHover($0, hostID: host.id) }
        .listRowBackground(
            rowFill(
                isSelected: false,
                isHovering: hoveredRecentHostID == host.id
            )
        )
        .listRowInsets(EdgeInsets())
        .contextMenu {
            HostContextMenu(host: host)
        }
        .help(Text("Quick Connect to \(app.hostLibrary.loginAddress(for: host))"))
        .accessibilityHint("Quick Connect with SSH")
    }

    private func rowFill(isSelected: Bool, isHovering: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if isHovering { return Color.primary.opacity(0.055) }
        return .clear
    }

    private func setPageHover(_ hovering: Bool, page: VaultPage) {
        if hovering {
            hoveredPage = page
        } else if hoveredPage == page {
            hoveredPage = nil
        }
    }

    private func setRecentHover(_ hovering: Bool, hostID: Host.ID) {
        if hovering {
            hoveredRecentHostID = hostID
        } else if hoveredRecentHostID == hostID {
            hoveredRecentHostID = nil
        }
    }

}

/// The first pinned tab's main content. Its navigator is mounted by the
/// window-level split view and remains alive while top-level tabs change.
struct VaultView: View {
    @Environment(WindowModel.self) private var window
    let hostsPageState: HostsPageState

    init(hostsPageState: HostsPageState = HostsPageState()) {
        self.hostsPageState = hostsPageState
    }

    var body: some View {
        destination
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var destination: some View {
        switch window.vaultDestination {
        case .welcome: WelcomeView()
        case .hosts: HostsPageView(state: hostsPageState)
        case .keychain: KeychainPageView()
        case .snippets: SnippetsPageView()
        }
    }
}

struct VaultWorkDetailView: View {
    let route: VaultWorkRoute

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    @ViewBuilder
    var body: some View {
        switch route {
        case .hostEditor(let id):
            HostEditorView(hostID: id)
        case .hostGroupEditor(let groupID, let parentID):
            NewGroupSheet(
                group: groupID.flatMap(app.hostLibrary.group), parentID: parentID,
                create: { group in
                    app.hostLibrary.upsert(group)
                    window.closeVaultWork()
                },
                close: window.closeVaultWork
            )
        case .identityEditor(let id):
            NewIdentitySheet(
                identity: id.flatMap(app.hostLibrary.identity),
                create: { identity, password in
                    try app.hostLibrary.upsert(identity, passwordUpdate: password)
                    window.selectDetail(.identity(identity.id), on: .keychain)
                },
                close: window.closeVaultWork
            )
        case .generateKey:
            KeychainGenerateDetail()
        case .importKey:
            KeychainImportDetail()
        case .editKey(let id):
            KeychainEditDetail(keyID: id)
        case .exportKeys(let ids):
            ExportKeyToHostsSheet(keys: ids.compactMap(app.hostLibrary.key))
        case .snippetEditor(let snippetID, let packageID):
            SnippetEditorSheet(
                snippet: snippetID.flatMap(app.hostLibrary.snippet), packageID: packageID,
                save: { snippet in
                    app.hostLibrary.upsert(snippet)
                    window.selectDetail(.snippet(snippet.id), on: .snippets)
                },
                close: window.closeVaultWork
            )
        case .snippetPackageEditor(let packageID, let parentID):
            SnippetPackageSheet(
                package: packageID.flatMap(app.hostLibrary.snippetPackage), parentID: parentID,
                save: { app.hostLibrary.upsert($0) }, close: window.closeVaultWork
            )
        case .snippetExecutionTargets(let request):
            SnippetExecutionTargetsView(request: request)
        }
    }
}
