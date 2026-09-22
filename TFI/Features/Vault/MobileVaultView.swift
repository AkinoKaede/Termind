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
    case telnet
    case sftp
    case edit
    case duplicate
    case delete
}

nonisolated enum MobileHostMenuPolicy {
    static let sections: [[MobileHostMenuAction]] = [
        [.ssh, .telnet, .sftp],
        [.edit, .duplicate],
        [.delete],
    ]
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
                        ContentUnavailableView("No History", systemImage: "clock.arrow.circlepath")
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
                            ForEach(MobileConnectionHistoryActionPolicy.menuKinds, id: \.self) { kind in
                                connectionButton(kind, host: row.host)
                            }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                app.connectionHistory.delete(row.entry.id)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                app.connectionHistory.delete(row.entry.id)
                            }
                            ForEach(MobileConnectionHistoryActionPolicy.swipeKinds, id: \.self) { kind in
                                connectionButton(kind, host: row.host)
                                    .tint(swipeTint(for: kind))
                            }
                        }
                }
            }
        }
        .searchable(text: $query.singleLineText, prompt: "Search History")
        .navigationTitle("History")
        .toolbar {
            MobileToolbarOverflow {
                Button("Clear History", systemImage: "trash", role: .destructive) {
                    clearingHistory = true
                }
                .disabled(app.connectionHistory.entries().isEmpty)
            }
        }
        .confirmationDialog(
            "Clear connection history?", isPresented: $clearingHistory,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                app.connectionHistory.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all connection history without deleting any Hosts.")
        }
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
        case .ssh: .blue
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

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    let app: MobileAppModel
    let reviewScene: MobileSceneModel?
    let activateHost: (Host.ID) -> Void
    let open: (UUID, ConnectionHistoryEntry.Kind) -> Void
    let executeSnippet: (Snippet, [Host.ID]) -> Void
    private let openMetrics: (() -> Void)?
    @Binding var editingHost: Host?
    @State private var query = ""
    @State private var deletingHost: Host?
    @State private var groupEditorRequest: GroupEditorRequest?
    @State private var deletingGroup: HostGroup?

    init(
        app: MobileAppModel,
        reviewScene: MobileSceneModel? = nil,
        editingHost: Binding<Host?>,
        activateHost: @escaping (Host.ID) -> Void,
        open: @escaping (UUID, ConnectionHistoryEntry.Kind) -> Void,
        executeSnippet: @escaping (Snippet, [Host.ID]) -> Void = { _, _ in },
        openMetrics: (() -> Void)? = nil
    ) {
        self.app = app
        self.reviewScene = reviewScene
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
    private var matchesMetricsPage: Bool { pageTitle("Metrics").localizedCaseInsensitiveContains(query) }
    private var matchesKeychainPage: Bool { pageTitle("Keychain").localizedCaseInsensitiveContains(query) }
    private var matchesSnippetsPage: Bool { pageTitle("Snippets").localizedCaseInsensitiveContains(query) }
    private var matchesKnownHostsPage: Bool { pageTitle("Known Hosts").localizedCaseInsensitiveContains(query) }
    private var matchesHistoryPage: Bool { pageTitle("History").localizedCaseInsensitiveContains(query) }
    private var hostSections: [HostLibrarySection] { HostLibrarySectionLayout.sections(library: app.library) }

    private var keychainSearchLinks: [SearchLink] {
        var result: [SearchLink] = []
        if matchesKeychainPage {
            result.append(
                SearchLink(
                    id: "keychain-page", title: pageTitle("Keychain"), detail: nil,
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
        if pageTitle("Port Forwarding").localizedCaseInsensitiveContains(query) {
            result.append(
                SearchLink(
                    id: "forwarding-page", title: pageTitle("Port Forwarding"), detail: nil,
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
                    id: "snippets-page", title: pageTitle("Snippets"), detail: nil,
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
                    id: "known-hosts-page", title: pageTitle("Known Hosts"), detail: nil,
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
                    id: "history-page", title: pageTitle("History"), detail: nil,
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
                    id: "metrics-page", title: pageTitle("Metrics"), detail: nil,
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
                if app.library.hosts.isEmpty && app.library.groups.isEmpty {
                    ContentUnavailableView(
                        "No Hosts", systemImage: "server.rack",
                        description: Text("Add a host to connect with SSH or SFTP.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                }
                ForEach(hostSections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        hostSectionHeader(section)
                        if section.isExpanded != false {
                            MobileCardGrid {
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
        .navigationTitle("Vault")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Host", systemImage: "server.rack") { editingHost = Host(name: "", host: "") }
                    Button("New Group", systemImage: "folder.badge.plus") {
                        groupEditorRequest = GroupEditorRequest(groupID: nil, parentID: nil)
                    }
                } label: {
                    Label("Add", systemImage: "plus").labelStyle(.iconOnly)
                }
            }
        }
        .sheet(item: $editingHost) { MobileHostEditor(app: app, host: $0) }
        .sheet(item: $groupEditorRequest) { request in
            MobileHostGroupEditor(
                app: app,
                group: request.groupID.flatMap(app.library.group),
                parentID: request.parentID)
        }
        .confirmationDialog(
            "Delete Host?", isPresented: Binding(get: { deletingHost != nil }, set: { if !$0 { deletingHost = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let host = deletingHost { app.deleteHost(host.id) }
                deletingHost = nil
            }
        } message: {
            Text("Open connections and references to this host will be removed.")
        }
        .confirmationDialog(
            groupDeletionTitle,
            isPresented: Binding(
                get: { deletingGroup != nil },
                set: { if !$0 { deletingGroup = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Group and Hosts", role: .destructive) {
                deleteGroup(keepingHosts: false)
            }
            Button("Keep Hosts") { deleteGroup(keepingHosts: true) }
            Button("Cancel", role: .cancel) { deletingGroup = nil }
        } message: {
            Text(groupDeletionMessage)
        }
        .mobileReviewPage("vault.hosts", scene: reviewScene)
    }

    @ViewBuilder
    private var searchResults: some View {
        if !hasSearchResults {
            ContentUnavailableView.search(text: query)
        }
        if !matchingHosts.isEmpty {
            MobileCardSection(title: "Hosts", count: matchingHosts.count) {
                MobileCardGrid { ForEach(matchingHosts) { row($0) } }
            }
        }
        if !keychainSearchLinks.isEmpty {
            MobileCardSection(title: "Keychain") {
                MobileVaultLinkGroup {
                    searchLinkRows(keychainSearchLinks)
                }
            }
        }
        if !forwardingSearchLinks.isEmpty {
            MobileCardSection(title: "Port Forwarding") {
                MobileVaultLinkGroup { searchLinkRows(forwardingSearchLinks) }
            }
        }
        if !snippetSearchLinks.isEmpty {
            MobileCardSection(title: "Snippets") {
                MobileVaultLinkGroup {
                    searchLinkRows(snippetSearchLinks)
                }
            }
        }
        if !knownHostSearchLinks.isEmpty {
            MobileCardSection(title: "Known Hosts") {
                MobileVaultLinkGroup {
                    searchLinkRows(knownHostSearchLinks)
                }
            }
        }
        if !historySearchLinks.isEmpty {
            MobileCardSection(title: "History") {
                MobileVaultLinkGroup {
                    searchLinkRows(historySearchLinks)
                }
            }
        }
        if !metricSearchLinks.isEmpty {
            MobileCardSection(title: "Metrics") {
                MobileVaultLinkGroup {
                    searchLinkRows(metricSearchLinks)
                }
            }
        }
    }

    @ViewBuilder
    private var vaultLinks: some View {
        MobileVaultLinkGroup {
            vaultLink("Keychain", symbol: "key") {
                MobileCredentialsView(app: app)
                    .mobileReviewPage("vault.keychain", scene: reviewScene)
            }
            MobileVaultLinkDivider()
            vaultLink("Port Forwarding", symbol: "arrow.left.arrow.right") {
                MobileForwardingView(app: app, reviewScene: reviewScene)
                    .mobileReviewPage("vault.portForwarding", scene: reviewScene)
            }
            MobileVaultLinkDivider()
            vaultLink("Snippets", symbol: "curlybraces") {
                MobileSnippetsView(app: app, execute: executeSnippet)
                    .mobileReviewPage("vault.snippets", scene: reviewScene)
            }
            MobileVaultLinkDivider()
            vaultLink("Known Hosts", symbol: "touchid") {
                MobileKnownHostsView(app: app)
                    .mobileReviewPage("vault.knownHosts", scene: reviewScene)
            }
            MobileVaultLinkDivider()
            vaultLink("History", symbol: "clock.arrow.circlepath") {
                MobileConnectionHistoryView(app: app, open: open)
                    .mobileReviewPage("vault.history", scene: reviewScene)
            }
        }
    }

    private func vaultLink<Destination: View>(
        _ title: LocalizedStringKey, symbol: String,
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
                .mobileReviewPage("vault.keychain", scene: reviewScene)
        case .portForwarding(let useQuery):
            MobileForwardingView(app: app, initialQuery: useQuery ? query : "", reviewScene: reviewScene)
                .mobileReviewPage("vault.portForwarding", scene: reviewScene)
        case .snippets(let useQuery):
            MobileSnippetsView(
                app: app, initialQuery: useQuery ? query : "", execute: executeSnippet
            )
            .mobileReviewPage("vault.snippets", scene: reviewScene)
        case .knownHosts(let useQuery):
            MobileKnownHostsView(app: app, initialQuery: useQuery ? query : "")
                .mobileReviewPage("vault.knownHosts", scene: reviewScene)
        case .history(let useQuery):
            MobileConnectionHistoryView(
                app: app, initialQuery: useQuery ? query : "", open: open
            )
            .mobileReviewPage("vault.history", scene: reviewScene)
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
                    Button("New Host", systemImage: "server.rack") {
                        editingHost = Host(name: "", host: "", groupID: group.id)
                    }
                    Button("New Subgroup", systemImage: "folder.badge.plus") {
                        groupEditorRequest = GroupEditorRequest(groupID: nil, parentID: group.id)
                    }
                    Button("Edit", systemImage: "pencil") {
                        groupEditorRequest = GroupEditorRequest(groupID: group.id, parentID: group.parentID)
                    }
                    Divider()
                    Button("Delete Group", systemImage: "trash", role: .destructive) {
                        requestDelete(group)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("More")
            } else if case .ungrouped = section.id {
                Menu {
                    Button("New Host", systemImage: "server.rack") {
                        editingHost = Host(name: "", host: "")
                    }
                    Button("New Group", systemImage: "folder.badge.plus") {
                        groupEditorRequest = GroupEditorRequest(groupID: nil, parentID: nil)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("More")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func requestDelete(_ group: HostGroup) {
        if app.library.hosts(inTreeOf: group.id).isEmpty {
            app.deleteHostGroup(group.id, keepHosts: false)
        } else {
            deletingGroup = group
        }
    }

    private var groupDeletionTitle: String {
        guard let group = deletingGroup else { return "" }
        return String(
            localized: "Delete “\(group.name)”?"
        )
    }

    private var groupDeletionMessage: String {
        guard let group = deletingGroup else { return "" }
        let hosts = app.library.hosts(inTreeOf: group.id).count
        let nested = app.library.descendantGroups(of: group.id).count
        let hostCount = String(localized: "\(hosts) hosts")
        if nested == 0 {
            return String(localized: "This group contains \(hostCount).")
        }
        let groupCount =
            nested == 1
            ? String(localized: "1 nested group")
            : String(localized: "\(nested) nested groups")
        return String(localized: "This group contains \(hostCount) and \(groupCount). Nested groups will be deleted.")
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

    private func pageTitle(_ value: String.LocalizationValue) -> String {
        String(localized: value)
    }

    private func row(_ host: Host) -> some View {
        let entry = LinuxDistributionIconCatalog.entry(for: host.detectedDistribution)
        let brand = entry.flatMap {
            LinuxDistributionBrandColor.color(hex: $0.hex, colorScheme: colorScheme)
        }
        let tint = host.colorTag.color ?? brand ?? .accentColor
        return MobileActionCard {
            activateHost(host.id)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    HostSystemIcon(asset: entry?.asset, size: 36)
                        .tint(tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(host.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                        Text(app.library.preferredTerminalLoginAddress(for: host)).font(.caption.monospaced())
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 6) {
                    ForEach(MobileCardLayout.visibleTags(host.tags), id: \.self) { tag in
                        MobileCardChip(text: tag)
                    }
                    Spacer(minLength: 6)
                    Text(
                        app.lastConnectedAt(for: host.id)
                            .map { $0.formatted(.relative(presentation: .numeric).locale(locale)) }
                            ?? String(localized: "Never")
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint("Open Workspace")
        } actions: {
            ForEach(MobileHostMenuPolicy.sections.indices, id: \.self) { section in
                ForEach(MobileHostMenuPolicy.sections[section], id: \.self) { action in
                    hostMenuButton(action, host: host)
                }
                if section < MobileHostMenuPolicy.sections.count - 1 {
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func hostMenuButton(_ action: MobileHostMenuAction, host: Host) -> some View {
        switch action {
        case .ssh:
            Button("SSH", systemImage: ConnectionHistoryEntry.Kind.ssh.symbol) { open(host.id, .ssh) }
                .disabled(!host.sshEnabled)
        case .telnet:
            Button("Telnet", systemImage: ConnectionHistoryEntry.Kind.telnet.symbol) { open(host.id, .telnet) }
                .disabled(!host.telnetEnabled)
        case .sftp:
            Button("SFTP", systemImage: ConnectionHistoryEntry.Kind.sftp.symbol) { open(host.id, .sftp) }
                .disabled(!host.sshEnabled)
        case .edit:
            Button("Edit", systemImage: "pencil") { editingHost = host }
        case .duplicate:
            Button("Duplicate", systemImage: "plus.square.on.square") { app.duplicateHost(host) }
        case .delete:
            Button("Delete", systemImage: "trash", role: .destructive) { deletingHost = host }
        }
    }
}

struct MobileHostGroupEditor: View {
    let app: MobileAppModel
    let original: HostGroup
    let existing: Bool
    let didSave: (HostGroup) -> Void
    @State private var draft: HostGroup
    @Environment(\.dismiss) private var dismiss

    init(
        app: MobileAppModel, group: HostGroup?, parentID: HostGroup.ID?,
        didSave: @escaping (HostGroup) -> Void = { _ in }
    ) {
        self.app = app
        let initial = group ?? HostGroup(name: "", parentID: parentID)
        original = initial
        existing = group != nil
        self.didSave = didSave
        _draft = State(initialValue: initial)
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        MobileEditorSheet(
            title: existing ? String(localized: "Edit Group") : String(localized: "New Group"),
            isDirty: draft != original, canSave: !trimmedName.isEmpty, compact: true,
            save: save
        ) {
            TextField("Name", text: $draft.name.singleLineText, axis: .horizontal)
                .singleLinePaste()
                .lineLimit(1)
            Picker("Inside", selection: $draft.parentID) {
                Text("Top Level").tag(HostGroup.ID?.none)
                ForEach(parentChoices, id: \.group.id) { choice in
                    Text(choice.path).tag(HostGroup.ID?.some(choice.group.id))
                }
            }
        }
        .onChange(of: app.library.groups.map(\.id)) {
            if existing && !app.library.groups.contains(where: { $0.id == original.id }) {
                dismiss()
            }
        }
    }

    private var parentChoices: [(group: HostGroup, path: String)] {
        let forbidden = Set([draft.id] + app.library.descendantGroups(of: draft.id).map(\.id))
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
        draft.name = trimmedName
        app.library.upsert(draft)
        if let error = app.library.storageError { throw MobileEditorError.message(error) }
        didSave(draft)
    }
}
