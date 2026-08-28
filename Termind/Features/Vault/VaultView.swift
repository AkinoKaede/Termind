import AppKit
import ListViewKit
import SwiftUI

/// Vault's navigation mode inside the window's one shared sidebar.
struct VaultSidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @AppStorage(SettingsKey.compactSidebar) private var compactSidebar = false
    @AppStorage(SettingsKey.showRecents) private var showRecents = true
    var body: some View {
        VaultNavigationNativeList(items: items, compactSidebar: compactSidebar) { item in
            renderedItem(item)
        }
        .termindSidebarSurface()
    }

    private var items: [VaultNavigationItem] {
        var result: [VaultNavigationItem] = [
            .page(.welcome, count: 0, selected: window.vaultDestination.page == .welcome),
            .section(.vault),
            .page(.hosts, count: app.hostLibrary.hosts.count, selected: window.vaultDestination.page == .hosts),
            .page(
                .keychain,
                count: app.hostLibrary.keys.count + app.hostLibrary.identities.count,
                selected: window.vaultDestination.page == .keychain
            ),
            .page(.snippets, count: app.hostLibrary.snippets.count, selected: window.vaultDestination.page == .snippets),
        ]
        if showRecents, !recentHosts.isEmpty {
            result.append(.section(.recents))
            result.append(contentsOf: recentHosts.map { host in
                .recent(
                    host,
                    address: app.hostLibrary.loginAddress(for: host),
                    status: app.hostLibrary.status(of: host.id),
                    compact: compactSidebar
                )
            })
        }
        return result
    }

    @ViewBuilder
    private func renderedItem(_ item: VaultNavigationItem) -> some View {
        switch item.content {
        case .section(let section):
            Text(section.title)
                .termindSidebarSectionLabel()
                .padding(.horizontal, Metrics.Sidebar.navigationRowInset)
                .padding(.top, Metrics.Space.m)
                .padding(.bottom, Metrics.Space.xs)
        case .page(let page, let count, _):
            row(page, count: count)
        case .recent(let host, _, _, _):
            recentRow(host)
        }
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .termindSidebarRowBackground(isSelected: isSelected)
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
        .termindSidebarRowBackground(isSelected: false)
        .contextMenu {
            HostContextMenu(host: host)
        }
        .help(Text("Quick Connect to \(app.hostLibrary.loginAddress(for: host))"))
        .accessibilityHint("Quick Connect with SSH")
    }

}

nonisolated struct VaultNavigationItem: Identifiable, Hashable, Sendable {
    nonisolated enum Section: Hashable, Sendable {
        case vault
        case recents

        var title: LocalizedStringKey {
            switch self {
            case .vault: "Vault"
            case .recents: "Recents"
            }
        }
    }

    nonisolated enum ID: Hashable, Sendable {
        case section(Section)
        case page(VaultPage)
        case recent(Host.ID)
    }

    nonisolated enum Content: Hashable, Sendable {
        case section(Section)
        case page(VaultPage, count: Int, selected: Bool)
        case recent(Host, address: String, status: ConnectionStatus, compact: Bool)
    }

    let id: ID
    let content: Content

    static func section(_ section: Section) -> Self {
        .init(id: .section(section), content: .section(section))
    }

    static func page(_ page: VaultPage, count: Int, selected: Bool) -> Self {
        .init(id: .page(page), content: .page(page, count: count, selected: selected))
    }

    static func recent(
        _ host: Host,
        address: String,
        status: ConnectionStatus,
        compact: Bool
    ) -> Self {
        .init(
            id: .recent(host.id),
            content: .recent(host, address: address, status: status, compact: compact)
        )
    }

    var height: CGFloat {
        switch content {
        case .section: 34
        case .page: Metrics.Sidebar.navigationRowHeight
        case .recent(_, _, _, let compact):
            compact ? Metrics.Sidebar.navigationRowHeight : 44
        }
    }
}

private struct VaultNavigationNativeList: NSViewRepresentable {
    typealias NSViewType = ListView<VaultNavigationItem>
    typealias Renderer = @MainActor (VaultNavigationItem) -> AnyView

    let items: [VaultNavigationItem]
    let compactSidebar: Bool
    let renderer: Renderer

    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    init(
        items: [VaultNavigationItem],
        compactSidebar: Bool,
        @ViewBuilder renderer: @escaping @MainActor (VaultNavigationItem) -> some View
    ) {
        self.items = items
        self.compactSidebar = compactSidebar
        self.renderer = { AnyView(renderer($0)) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSViewType {
        context.coordinator.makeListView()
    }

    func updateNSView(_ listView: NSViewType, context: Context) {
        context.coordinator.update(
            listView: listView,
            items: items,
            renderer: renderer,
            locale: locale,
            colorScheme: colorScheme,
            compactSidebar: compactSidebar
        )
    }

    @MainActor
    final class Coordinator {
        private var renderer: Renderer?
        private var locale = Locale.current
        private var colorScheme = ColorScheme.light
        private var content: [VaultNavigationItem] = []

        func makeListView() -> NSViewType {
            let listView = NSViewType()
            listView.rowAnimator = ListBouncyAnimator(style: .regular)
            listView.rows {
                ListRow(VaultNavigationHostingRow.self)
                    .height { item, _ in item.height }
                    .configure { [weak self] row, item, _ in
                        self?.configure(row, item: item)
                    }
            }
            return listView
        }

        func update(
            listView: NSViewType,
            items: [VaultNavigationItem],
            renderer: @escaping Renderer,
            locale: Locale,
            colorScheme: ColorScheme,
            compactSidebar _: Bool
        ) {
            self.renderer = renderer
            let environmentChanged = self.locale != locale || self.colorScheme != colorScheme
            self.locale = locale
            self.colorScheme = colorScheme
            if content.map(\.id) == items.map(\.id) {
                for (old, new) in zip(content, items) where environmentChanged || old != new {
                    listView.update(new)
                }
            } else {
                listView.apply(items, animated: !content.isEmpty)
            }
            content = items
        }

        private func configure(_ row: VaultNavigationHostingRow, item: VaultNavigationItem) {
            guard let renderer else { return }
            let content = renderer(item)
                .id(item.id)
                .environment(\.locale, locale)
                .environment(\.colorScheme, colorScheme)
            row.configure(rootView: AnyView(content))
        }
    }
}

@MainActor
private final class VaultNavigationHostingRow: ListRowView {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame: CGRect) {
        super.init(frame: frame)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hostingView.rootView = AnyView(EmptyView())
    }

    func configure(rootView: AnyView) {
        hostingView.rootView = rootView
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
