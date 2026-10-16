import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

enum MobileHistoryPresentation {
    static let limit = 50

    static func limited<Entry>(_ entries: [Entry]) -> [Entry] {
        Array(entries.prefix(limit))
    }
}

enum MobileHostMenuAction: Hashable, Sendable {
    case ssh
    case mosh
    case eternalTerminal
    case telnet
    case sftp
    case wake
    case edit
    case tailscale
    case duplicate
    case delete
}

nonisolated enum MobileHostMenuPolicy {
    static let sections: [[MobileHostMenuAction]] = [
        [.ssh, .mosh, .eternalTerminal, .telnet, .sftp],
        [.wake, .tailscale],
        [.edit, .duplicate],
        [.delete],
    ]

    static func sections(for host: Host, hasTailscalePeer: Bool = false) -> [[MobileHostMenuAction]] {
        sections.compactMap { section in
            let available = section.filter { action in
                switch action {
                case .ssh, .sftp: host.sshEnabled
                case .telnet: host.telnetEnabled
                case .mosh: host.isEnabled(.mosh)
                case .eternalTerminal: host.isEnabled(.eternalTerminal)
                case .tailscale: host.isTailscaleManaged || hasTailscalePeer
                case .wake, .edit, .duplicate, .delete: true
                }
            }
            return available.isEmpty ? nil : available
        }
    }
}

struct MobileConnectionHistoryView: View {
    let app: MobileAppModel
    let open: (Host.ID, ConnectionHistoryEntry.Kind) -> Void
    @Environment(\.locale) private var locale
    @State private var query: String
    @State private var clearingHistory = false

    init(
        app: MobileAppModel, initialQuery: String = "",
        open: @escaping (Host.ID, ConnectionHistoryEntry.Kind) -> Void
    ) {
        self.app = app
        self.open = open
        _query = State(initialValue: initialQuery)
    }

    private var rows: [MobileConnectionHistoryRow] {
        _ = app.connectionHistory.revision
        return MobileConnectionHistory.eventRows(
            history: app.connectionHistory, devices: app.devices, library: app.library,
            query: query, limit: MobileHistoryPresentation.limit)
    }

    var body: some View {
        List {
            if rows.isEmpty {
                Group {
                    if query.isEmpty {
                        ContentUnavailableView(
                            AppStrings.Common.noHistory.swiftUIKey, systemImage: "clock.arrow.circlepath")
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(rows) { row in
                    historyButton(row)
                        .contextMenu {
                            let kinds = MobileConnectionHistoryActionPolicy.availableMenuKinds(for: row.host)
                            ForEach(kinds, id: \.self) { kind in
                                connectionButton(kind, host: row.host)
                            }
                            if !kinds.isEmpty { Divider() }
                            Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                                app.connectionHistory.delete(row.entry.id)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                                app.connectionHistory.delete(row.entry.id)
                            }
                            ForEach(
                                MobileConnectionHistoryActionPolicy.availableSwipeKinds(for: row.host), id: \.self
                            ) { kind in
                                connectionButton(kind, host: row.host)
                                    .tint(swipeTint(for: kind))
                            }
                        }
                }
            }
        }
        .searchable(text: $query.singleLineText, prompt: AppStrings.Common.searchHistory.swiftUIKey)
        .navigationTitle(AppStrings.Common.history.swiftUIKey)
        .toolbar {
            MobileToolbarOverflow {
                Button(AppStrings.Common.clearAll.swiftUIKey, systemImage: "trash", role: .destructive) {
                    clearingHistory = true
                }
                .disabled(app.connectionHistory.entries().isEmpty)
            }
        }
        .operationConfirmation(
            .init(AppStrings.Connections.clearConnectionHistoryConfirmation), isPresented: $clearingHistory,
            placement: .centered,
            actions: [
                .init(AppStrings.Common.clearHistory, role: .destructive) {
                    app.connectionHistory.clearAll()
                },
                .init(AppStrings.Common.cancel, role: .cancel) {},
            ],
            message: .init(AppStrings.Workspace.clearHistoryWarning)
        )
    }

    @ViewBuilder
    private func historyButton(_ row: MobileConnectionHistoryRow) -> some View {
        if row.canOpen {
            Button {
                open(row.host.id, row.entry.kind)
            } label: {
                historyLabel(row)
            }
            .buttonStyle(.plain)
        } else {
            historyLabel(row)
                .opacity(0.55)
        }
    }

    private func historyLabel(_ row: MobileConnectionHistoryRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.entry.kind.symbol)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .accessibilityLabel(Text(row.entry.kind.label))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 12) {
                    Text(row.host.name).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(row.sourceDeviceName ?? "—")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(alignment: .center, spacing: 12) {
                    Text(row.loginAddress)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(row.entry.connectedAt, format: .relative(presentation: .numeric).locale(locale))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func connectionButton(
        _ kind: ConnectionHistoryEntry.Kind, host: Host
    ) -> some View {
        Button(kind.label, systemImage: kind.symbol) {
            guard MobileConnectionHistoryActionPolicy.isAvailable(kind, for: host) else { return }
            open(host.id, kind)
        }
        .disabled(!MobileConnectionHistoryActionPolicy.isAvailable(kind, for: host))
    }

    private func swipeTint(for kind: ConnectionHistoryEntry.Kind) -> Color {
        switch kind {
        case .ssh, .mosh, .eternalTerminal: .accentColor
        case .telnet: .purple
        case .sftp: .orange
        }
    }
}

private struct MobileVaultLinkGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26, *) {
            surface(
                shape: ConcentricRectangle(corners: .concentric(minimum: 20), isUniform: true),
                containerRadius: 20)
        } else {
            surface(
                shape: RoundedRectangle(cornerRadius: 10, style: .continuous),
                containerRadius: 10)
        }
    }

    private func surface<S: Shape>(shape: S, containerRadius: CGFloat) -> some View {
        VStack(spacing: 0) { content }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
            .clipShape(shape)
            .containerShape(
                RoundedRectangle(cornerRadius: containerRadius, style: .continuous)
            )
    }
}

private struct MobileVaultLinkLabel: View {
    let title: Text
    let detail: Text?
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                title.foregroundStyle(.primary).lineLimit(1)
                if let detail {
                    detail.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(.rect)
    }
}

private struct MobileVaultLinkDivider: View {
    var body: some View {
        Divider().padding(.leading, 52)
    }
}

struct MobileVaultView: View {
    @AppStorage("mobile.compactCards") private var compactCards = false
    private struct GroupEditorRequest: Identifiable {
        let id = UUID()
        let groupID: HostGroup.ID?
        let parentID: HostGroup.ID?
    }

    private enum SearchDestination {
        case keychain(useQuery: Bool)
        case portForwarding(useQuery: Bool)
        case snippets(useQuery: Bool)
        case knownHosts(useQuery: Bool)
        case history(useQuery: Bool)
        case metrics
    }

    private struct SearchLink: Identifiable {
        let id: String
        let title: String
        let detail: String?
        let symbol: String
        let destination: SearchDestination
    }

    @Environment(\.locale) private var locale

    let app: MobileAppModel
    let scene: MobileSceneModel?
    let activateHost: (Host.ID) -> Void
    let open: (UUID, ConnectionHistoryEntry.Kind) -> Void
    let executeSnippet: (Snippet, [Host.ID]) -> Void
    private let openMetrics: (() -> Void)?
    @Binding var editingHost: Host?
    @State private var discoverNewHost = false
    @State private var wakeNotice: String?
    @State private var query = ""
    @State private var tailscaleHost: Host?
    @State private var deletingHost: Host?
    @State private var groupEditorRequest: GroupEditorRequest?
    @State private var deletingGroup: HostGroup?
    @State private var reviewVisit = AppReviewInvitationVisit()

    init(
        app: MobileAppModel,
        scene: MobileSceneModel? = nil,
        editingHost: Binding<Host?>,
        activateHost: @escaping (Host.ID) -> Void,
        open: @escaping (UUID, ConnectionHistoryEntry.Kind) -> Void,
        executeSnippet: @escaping (Snippet, [Host.ID]) -> Void = { _, _ in },
        openMetrics: (() -> Void)? = nil
    ) {
        self.app = app
        self.scene = scene
        _editingHost = editingHost
        self.activateHost = activateHost
        self.open = open
        self.executeSnippet = executeSnippet
        self.openMetrics = openMetrics
    }

    private var matchingHosts: [Host] { app.library.searchHosts(query) }
    private var matchingKeys: [SSHKeyRef] { app.credentials.searchKeys(query) }
    private var matchingIdentities: [Identity] { app.credentials.searchIdentities(query) }
    private var matchingSnippets: [Snippet] { app.snippets.searchSnippets(query) }
    private var matchingKnownHosts: [KnownHostEntry] { app.knownHosts.search(query) }
    private var matchingMetricServers: [ServerMetric] {
        app.metrics.servers.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var matchesMetricsPage: Bool {
        pageTitle(AppStrings.Navigation.metrics).localizedCaseInsensitiveContains(query)
    }
    private var matchesKeychainPage: Bool {
        pageTitle(AppStrings.Navigation.keychain).localizedCaseInsensitiveContains(query)
    }
    private var matchesSnippetsPage: Bool {
        pageTitle(AppStrings.Navigation.snippets).localizedCaseInsensitiveContains(query)
    }
    private var matchesKnownHostsPage: Bool {
        pageTitle(AppStrings.Navigation.knownHosts).localizedCaseInsensitiveContains(query)
    }
    private var matchesHistoryPage: Bool {
        pageTitle(AppStrings.Common.history).localizedCaseInsensitiveContains(query)
    }
    private var hostSections: [HostLibrarySection] { HostLibrarySectionLayout.sections(library: app.library) }

    private var keychainSearchLinks: [SearchLink] {
        var result: [SearchLink] = []
        if matchesKeychainPage {
            result.append(
                SearchLink(
                    id: "keychain-page", title: pageTitle(AppStrings.Navigation.keychain), detail: nil,
                    symbol: "key", destination: .keychain(useQuery: false)))
        }
        result += matchingKeys.map {
            SearchLink(
                id: "key-\($0.id)", title: $0.label, detail: $0.fingerprint,
                symbol: "key", destination: .keychain(useQuery: true))
        }
        result += matchingIdentities.map {
            SearchLink(
                id: "identity-\($0.id)", title: $0.name.isEmpty ? $0.username : $0.name,
                detail: $0.username, symbol: "person.crop.square", destination: .keychain(useQuery: true))
        }
        return result
    }

    private var forwardingSearchLinks: [SearchLink] {
        var result: [SearchLink] = []
        if pageTitle(AppStrings.Navigation.portForwarding).localizedCaseInsensitiveContains(query) {
            result.append(
                SearchLink(
                    id: "forwarding-page", title: pageTitle(AppStrings.Navigation.portForwarding), detail: nil,
                    symbol: "arrow.left.arrow.right", destination: .portForwarding(useQuery: false)))
        }
        result += app.forwardingLibrary.search(query).map { rule in
            SearchLink(
                id: "forwarding-\(rule.id)", title: rule.displayName(hostName: app.library.host(rule.hostID)?.name),
                detail: rule.summary, symbol: rule.kind.symbol, destination: .portForwarding(useQuery: true))
        }
        return result
    }

    private var snippetSearchLinks: [SearchLink] {
        var result: [SearchLink] = []
        if matchesSnippetsPage {
            result.append(
                SearchLink(
                    id: "snippets-page", title: pageTitle(AppStrings.Navigation.snippets), detail: nil,
                    symbol: "curlybraces", destination: .snippets(useQuery: false)))
        }
        result += matchingSnippets.map {
            SearchLink(
                id: "snippet-\($0.id)", title: $0.title, detail: $0.body,
                symbol: "curlybraces", destination: .snippets(useQuery: true))
        }
        return result
    }

    private var knownHostSearchLinks: [SearchLink] {
        var result: [SearchLink] = []
        if matchesKnownHostsPage {
            result.append(
                SearchLink(
                    id: "known-hosts-page", title: pageTitle(AppStrings.Navigation.knownHosts), detail: nil,
                    symbol: "touchid", destination: .knownHosts(useQuery: false)))
        }
        result += matchingKnownHosts.map {
            SearchLink(
                id: "known-host-\($0.id)", title: $0.displayAddress, detail: nil,
                symbol: "touchid", destination: .knownHosts(useQuery: true))
        }
        return result
    }

    private var historySearchLinks: [SearchLink] {
        var result: [SearchLink] = []
        if matchesHistoryPage {
            result.append(
                SearchLink(
                    id: "history-page", title: pageTitle(AppStrings.Common.history), detail: nil,
                    symbol: "clock.arrow.circlepath", destination: .history(useQuery: false)))
        }
        result += MobileConnectionHistory.eventRows(
            history: app.connectionHistory, devices: app.devices, library: app.library,
            query: query, limit: MobileHistoryPresentation.limit
        ).map { row in
            SearchLink(
                id: "history-\(row.entry.id)", title: row.host.name,
                detail: row.sourceDeviceName,
                symbol: row.entry.kind.symbol, destination: .history(useQuery: true))
        }
        return result
    }

    private var metricSearchLinks: [SearchLink] {
        guard openMetrics != nil else { return [] }
        var result: [SearchLink] = []
        if matchesMetricsPage {
            result.append(
                SearchLink(
                    id: "metrics-page", title: pageTitle(AppStrings.Navigation.metrics), detail: nil,
                    symbol: "waveform.path.ecg", destination: .metrics))
        }
        result += matchingMetricServers.map {
            SearchLink(
                id: "metric-\($0.id)", title: $0.name, detail: nil,
                symbol: "waveform.path.ecg", destination: .metrics)
        }
        return result
    }

    private var hasSearchResults: Bool {
        !matchingHosts.isEmpty || !keychainSearchLinks.isEmpty || !snippetSearchLinks.isEmpty
            || !forwardingSearchLinks.isEmpty || !knownHostSearchLinks.isEmpty
            || !historySearchLinks.isEmpty || !metricSearchLinks.isEmpty
    }

    var body: some View {
        MobileCardPage {
            if query.isEmpty {
                vaultLinks
                if reviewVisit.isVisible(
                    controller: app.appReview, hasHosts: !app.library.hosts.isEmpty, isFiltering: false
                ) {
                    AppReviewInvitationView(controller: app.appReview)
                }
                if app.library.hosts.isEmpty && app.library.groups.isEmpty {
                    ContentUnavailableView(
                        AppStrings.Vault.noHosts.swiftUIKey, systemImage: "server.rack",
                        description: Text(AppStrings.Vault.addAHostToConnectWithSshOrSftp)
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                }
                ForEach(hostSections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        hostSectionHeader(section)
                        if section.isExpanded != false {
                            MobileCardGrid(compact: compactCards) {
                                ForEach(section.hosts) { row($0) }
                            }
                        }
                    }
                }
            } else {
                searchResults
            }
        }
        .searchable(text: $query.singleLineText)
        .onAppear {
            reviewVisit.enter(controller: app.appReview, hasHosts: !app.library.hosts.isEmpty)
        }
        .navigationTitle(AppStrings.Navigation.vault.swiftUIKey)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(AppStrings.Vault.newHost.swiftUIKey, systemImage: "server.rack") {
                        editingHost = Host(name: "", host: "")
                    }
                    Button(AppStrings.LocalNetwork.discovery.swiftUIKey, systemImage: "network") {
                        discoverNewHost = true
                        editingHost = Host(name: "", host: "")
                    }
                    Button(AppStrings.Vault.newGroup.swiftUIKey, systemImage: "folder.badge.plus") {
                        groupEditorRequest = GroupEditorRequest(groupID: nil, parentID: nil)
                    }
                } label: {
                    Label(AppStrings.Common.add.swiftUIKey, systemImage: "plus").labelStyle(.iconOnly)
                }
            }
        }
        .sheet(item: $tailscaleHost) { host in
            TailscalePeerView(model: app.tailscale, host: host) { UIPasteboard.general.string = $0 }
        }
        .sheet(item: $editingHost, onDismiss: { discoverNewHost = false }) {
            MobileHostEditor(app: app, host: $0, discover: discoverNewHost)
        }
        .alert(
            AppStrings.LocalNetwork.wake,
            isPresented: Binding(
                get: { wakeNotice != nil }, set: { if !$0 { wakeNotice = nil } }
            )
        ) {
            Button(AppStrings.Common.ok.swiftUIKey) { wakeNotice = nil }
        } message: {
            Text(wakeNotice ?? "")
        }
        .sheet(item: $groupEditorRequest) { request in
            MobileHostGroupEditor(
                app: app,
                group: request.groupID.flatMap(app.library.group),
                parentID: request.parentID)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if !hasSearchResults {
            ContentUnavailableView.search(text: query)
        }
        if !matchingHosts.isEmpty {
            MobileCardSection(title: AppStrings.Vault.hosts, count: matchingHosts.count) {
                MobileCardGrid(compact: compactCards) { ForEach(matchingHosts) { row($0) } }
            }
        }
        if !keychainSearchLinks.isEmpty {
            MobileCardSection(title: AppStrings.Navigation.keychain) {
                MobileVaultLinkGroup {
                    searchLinkRows(keychainSearchLinks)
                }
            }
        }
        if !forwardingSearchLinks.isEmpty {
            MobileCardSection(title: AppStrings.Navigation.portForwarding) {
                MobileVaultLinkGroup { searchLinkRows(forwardingSearchLinks) }
            }
        }
        if !snippetSearchLinks.isEmpty {
            MobileCardSection(title: AppStrings.Navigation.snippets) {
                MobileVaultLinkGroup {
                    searchLinkRows(snippetSearchLinks)
                }
            }
        }
        if !knownHostSearchLinks.isEmpty {
            MobileCardSection(title: AppStrings.Navigation.knownHosts) {
                MobileVaultLinkGroup {
                    searchLinkRows(knownHostSearchLinks)
                }
            }
        }
        if !historySearchLinks.isEmpty {
            MobileCardSection(title: AppStrings.Common.history) {
                MobileVaultLinkGroup {
                    searchLinkRows(historySearchLinks)
                }
            }
        }
        if !metricSearchLinks.isEmpty {
            MobileCardSection(title: AppStrings.Navigation.metrics) {
                MobileVaultLinkGroup {
                    searchLinkRows(metricSearchLinks)
                }
            }
        }
    }

    @ViewBuilder
    private var vaultLinks: some View {
        MobileVaultLinkGroup {
            vaultLink(AppStrings.Navigation.keychain, symbol: "key") {
                MobileCredentialsView(app: app)
            }
            MobileVaultLinkDivider()
            vaultLink(AppStrings.Navigation.portForwarding, symbol: "arrow.left.arrow.right") {
                MobileForwardingView(app: app)
            }
            MobileVaultLinkDivider()
            vaultLink(AppStrings.Navigation.snippets, symbol: "curlybraces") {
                MobileSnippetsView(app: app, execute: executeSnippet)
            }
            MobileVaultLinkDivider()
            vaultLink(AppStrings.Navigation.knownHosts, symbol: "touchid") {
                MobileKnownHostsView(app: app)
            }
            MobileVaultLinkDivider()
            vaultLink(AppStrings.Common.history, symbol: "clock.arrow.circlepath") {
                MobileConnectionHistoryView(app: app, open: open)
            }
        }
    }

    private func vaultLink<Destination: View>(
        _ title: LocalizedStringResource, symbol: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            MobileVaultLinkLabel(title: Text(title), detail: nil, symbol: symbol)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func searchLinkRows(_ links: [SearchLink]) -> some View {
        ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
            let label = MobileVaultLinkLabel(
                title: Text(verbatim: link.title),
                detail: link.detail.map { Text(verbatim: $0) }, symbol: link.symbol)
            Group {
                if case .metrics = link.destination {
                    Button {
                        openMetrics?()
                    } label: {
                        label
                    }
                } else {
                    NavigationLink {
                        searchDestination(link.destination)
                    } label: {
                        label
                    }
                }
            }
            .buttonStyle(.plain)
            if index < links.count - 1 {
                MobileVaultLinkDivider()
            }
        }
    }

    @ViewBuilder
    private func searchDestination(_ destination: SearchDestination) -> some View {
        switch destination {
        case .keychain(let useQuery):
            MobileCredentialsView(app: app, initialQuery: useQuery ? query : "")
        case .portForwarding(let useQuery):
            MobileForwardingView(app: app, initialQuery: useQuery ? query : "")
        case .snippets(let useQuery):
            MobileSnippetsView(
                app: app, initialQuery: useQuery ? query : "", execute: executeSnippet
            )
        case .knownHosts(let useQuery):
            MobileKnownHostsView(app: app, initialQuery: useQuery ? query : "")
        case .history(let useQuery):
            MobileConnectionHistoryView(
                app: app, initialQuery: useQuery ? query : "", open: open
            )
        case .metrics:
            EmptyView()
        }
    }

    private func hostSectionHeader(_ section: HostLibrarySection) -> some View {
        HStack(spacing: 8) {
            Button {
                toggle(section)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(section.isExpanded == true ? 90 : 0))
                    Text(section.title).font(.headline)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Text(section.hosts.count, format: .number)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            if case .group(let id) = section.id, let group = app.library.group(id) {
                Menu {
                    Button(AppStrings.Vault.newHost.swiftUIKey, systemImage: "server.rack") {
                        editingHost = Host(name: "", host: "", groupID: group.id)
                    }
                    Button(AppStrings.LocalNetwork.discovery.swiftUIKey, systemImage: "network") {
                        discoverNewHost = true
                        editingHost = Host(name: "", host: "", groupID: group.id)
                    }
                    Button(AppStrings.Vault.newSubgroup.swiftUIKey, systemImage: "folder.badge.plus") {
                        groupEditorRequest = GroupEditorRequest(groupID: nil, parentID: group.id)
                    }
                    Button(AppStrings.Common.edit.swiftUIKey, systemImage: "pencil") {
                        groupEditorRequest = GroupEditorRequest(groupID: group.id, parentID: group.parentID)
                    }
                    Divider()
                    Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                        requestDelete(group)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(AppStrings.Common.more.swiftUIKey)
                .operationConfirmation(
                    .init(groupDeletionTitle),
                    isPresented: $deletingGroup.isPresenting { $0.id == group.id },
                    actions: [
                        .init(AppStrings.Vault.deleteGroupAndHosts, role: .destructive) {
                            deleteGroup(keepingHosts: false)
                        },
                        .init(AppStrings.Vault.keepHosts) { deleteGroup(keepingHosts: true) },
                        .init(AppStrings.Common.cancel, role: .cancel) { deletingGroup = nil },
                    ],
                    message: .init(groupDeletionMessage)
                )
            } else if case .ungrouped = section.id {
                Menu {
                    Button(AppStrings.Vault.newHost.swiftUIKey, systemImage: "server.rack") {
                        editingHost = Host(name: "", host: "")
                    }
                    Button(AppStrings.LocalNetwork.discovery.swiftUIKey, systemImage: "network") {
                        discoverNewHost = true
                        editingHost = Host(name: "", host: "")
                    }
                    Button(AppStrings.Vault.newGroup.swiftUIKey, systemImage: "folder.badge.plus") {
                        groupEditorRequest = GroupEditorRequest(groupID: nil, parentID: nil)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(AppStrings.Common.more.swiftUIKey)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func requestDelete(_ group: HostGroup) {
        if DeletionContentCategory.protectedData.requiresConfirmation(for: .item) {
            deletingGroup = group
        } else {
            app.deleteHostGroup(group.id, keepHosts: false)
        }
    }

    private var groupDeletionTitle: String {
        guard let group = deletingGroup else { return "" }
        return String(
            localized: AppStrings.Common.deleteNamedConfirmation(group.name)
        )
    }

    private var groupDeletionMessage: String {
        guard let group = deletingGroup else { return "" }
        let hosts = app.library.hosts(inTreeOf: group.id).count
        let nested = app.library.descendantGroups(of: group.id).count
        return AppStrings.Vault.groupDeletionMessage(
            hostCount: hosts, nestedGroupCount: nested, locale: locale)
    }

    private func deleteGroup(keepingHosts: Bool) {
        guard let group = deletingGroup else { return }
        app.deleteHostGroup(group.id, keepHosts: keepingHosts)
        deletingGroup = nil
    }

    private func toggle(_ section: HostLibrarySection) {
        guard let isExpanded = section.isExpanded else { return }
        switch section.id {
        case .group(let id): app.library.setExpanded(!isExpanded, for: id)
        case .ungrouped: app.library.setUngroupedExpanded(!isExpanded)
        case .results: break
        }
    }

    private func pageTitle(_ value: LocalizedStringResource) -> String {
        String(localized: value)
    }

    private func row(_ host: Host) -> some View {
        MobileActionCard(compact: compactCards) {
            activateHost(host.id)
        } content: {
            MobileHostCardContent(
                host: host,
                address: app.library.preferredTerminalLoginAddress(for: host),
                status: scene?.workspaceActivatedByHostRow(for: host).flatMap {
                    MobileWorkspaceConnectionIndicator.resolve(
                        connected: $0.connected, busy: $0.busy, reconnecting: $0.reconnectState != nil
                    )?.status
                },
                lastConnectedAt: app.lastConnectedAt(for: host.id),
                compact: compactCards
            )
        } actions: {
            let sections = MobileHostMenuPolicy.sections(
                for: host, hasTailscalePeer: app.tailscale.peer(for: host) != nil)
            ForEach(sections.indices, id: \.self) { section in
                ForEach(sections[section], id: \.self) { action in
                    hostMenuButton(action, host: host)
                }
                if section < sections.count - 1 {
                    Divider()
                }
            }
        }
        .operationConfirmation(
            .init(AppStrings.Vault.deleteHostConfirmation),
            isPresented: $deletingHost.isPresenting { $0.id == host.id },
            actions: [
                .init(AppStrings.Common.delete, role: .destructive) {
                    if let host = deletingHost { app.deleteHost(host.id) }
                    deletingHost = nil
                },
                .init(AppStrings.Common.cancel, role: .cancel) { deletingHost = nil },
            ],
            message: .init(AppStrings.Vault.deleteHostWarning)
        )
    }

    @ViewBuilder
    private func hostMenuButton(_ action: MobileHostMenuAction, host: Host) -> some View {
        switch action {
        case .ssh:
            Button(AppStrings.Vault.ssh.swiftUIKey, systemImage: ConnectionHistoryEntry.Kind.ssh.symbol) {
                open(host.id, .ssh)
            }
        case .mosh:
            Button(AppStrings.Transports.mosh.swiftUIKey, systemImage: HostTerminalProtocol.mosh.symbol) {
                open(host.id, .mosh)
            }
        case .eternalTerminal:
            Button(
                AppStrings.Transports.eternalTerminal.swiftUIKey,
                systemImage: HostTerminalProtocol.eternalTerminal.symbol
            ) {
                open(host.id, .eternalTerminal)
            }
        case .telnet:
            Button(AppStrings.Vault.telnet.swiftUIKey, systemImage: ConnectionHistoryEntry.Kind.telnet.symbol) {
                open(host.id, .telnet)
            }
        case .sftp:
            Button(AppStrings.SFTP.sftp.swiftUIKey, systemImage: ConnectionHistoryEntry.Kind.sftp.symbol) {
                open(host.id, .sftp)
            }
        case .wake:
            Button(AppStrings.LocalNetwork.wake.swiftUIKey, systemImage: "power") {
                wakeNotice = app.requestWake(host) { editingHost = host }
            }
        case .edit:
            Button(AppStrings.Common.edit.swiftUIKey, systemImage: "pencil") { editingHost = host }
        case .tailscale:
            Button(AppStrings.Tailscale.title.swiftUIKey, systemImage: "point.3.connected.trianglepath.dotted") {
                tailscaleHost = host
            }
        case .duplicate:
            Button(AppStrings.Common.duplicate.swiftUIKey, systemImage: "plus.square.on.square") {
                app.duplicateHost(host)
            }.disabled(host.isTailscaleManaged)
        case .delete:
            Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                deletingHost = host
            }.disabled(host.isTailscaleManaged)
        }
    }
}

struct MobileHostGroupEditor: View {
    let app: MobileAppModel
    let existing: Bool
    let didSave: (HostGroup) -> Void
    @State private var editor: TailscaleGroupEditor
    @Environment(\.dismiss) private var dismiss

    init(
        app: MobileAppModel, group: HostGroup?, parentID: HostGroup.ID?,
        didSave: @escaping (HostGroup) -> Void = { _ in }
    ) {
        self.app = app
        existing = group != nil
        self.didSave = didSave
        _editor = State(initialValue: TailscaleGroupEditor(model: app.tailscale, group: group, parentID: parentID))
    }

    var body: some View {
        @Bindable var editor = editor
        MobileEditorSheet(
            title: existing
                ? String(localized: AppStrings.Vault.editGroup) : String(localized: AppStrings.Vault.newGroup),
            isDirty: editor.isDirty, canSave: editor.canSave, compact: true,
            discardQuestion: !existing
                ? AppStrings.Common.discardNewGroupQuestion : AppStrings.Common.discardChangesQuestion,
            save: save
        ) {
            Section {
                TextField(AppStrings.Common.name.swiftUIKey, text: $editor.draft.name.singleLineText, axis: .horizontal)
                    .singleLinePaste()
                    .lineLimit(1)
                Picker(AppStrings.Common.inside.swiftUIKey, selection: $editor.draft.parentID) {
                    Text(AppStrings.Common.topLevel).tag(HostGroup.ID?.none)
                    ForEach(parentChoices, id: \.group.id) { choice in
                        Text(choice.path).tag(HostGroup.ID?.some(choice.group.id))
                    }
                }
            }
            TailscaleGroupFields(editor: editor, requireAccess: { app.pro.require(.tailscale) }) { value in
                UIPasteboard.general.string = value
            }
        }
        .onDisappear { editor.cancel() }
        .onChange(of: app.library.groups.map(\.id)) {
            if existing && !app.library.groups.contains(where: { $0.id == editor.draft.id }) { dismiss() }
        }
    }

    private var parentChoices: [(group: HostGroup, path: String)] {
        let forbidden = Set([editor.draft.id] + app.library.descendantGroups(of: editor.draft.id).map(\.id))
        return app.library.groups.filter { !forbidden.contains($0.id) }
            .map { ($0, path(to: $0)) }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private func path(to group: HostGroup) -> String {
        var names = [group.name]
        var parentID = group.parentID
        var visited: Set<HostGroup.ID> = [group.id]
        while let id = parentID, let parent = app.library.group(id), visited.insert(id).inserted {
            names.append(parent.name)
            parentID = parent.parentID
        }
        return names.reversed().joined(separator: " / ")
    }

    private func save() async throws {
        didSave(try await editor.save())
    }
}
