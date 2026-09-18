import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

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
    private enum SearchDestination {
        case keychain(useQuery: Bool)
        case snippets(useQuery: Bool)
        case knownHosts(useQuery: Bool)
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
    let showsMetrics: Bool
    let executeSnippet: (Snippet, [Host.ID]) -> Void
    private let metricsPresentation: Binding<Bool>?
    @State private var localMetricsPresented = false
    @Binding var editingHost: Host?
    @State private var query = ""
    @State private var deletingHost: Host?
    @State private var groupName = ""
    @State private var addingGroup = false

    init(
        app: MobileAppModel,
        reviewScene: MobileSceneModel? = nil,
        editingHost: Binding<Host?>,
        activateHost: @escaping (Host.ID) -> Void,
        open: @escaping (UUID, ConnectionHistoryEntry.Kind) -> Void,
        showsMetrics: Bool = true,
        executeSnippet: @escaping (Snippet, [Host.ID]) -> Void = { _, _ in },
        metricsPresentation: Binding<Bool>? = nil
    ) {
        self.app = app
        self.reviewScene = reviewScene
        _editingHost = editingHost
        self.activateHost = activateHost
        self.open = open
        self.showsMetrics = showsMetrics
        self.executeSnippet = executeSnippet
        self.metricsPresentation = metricsPresentation
    }

    private var presentsMetrics: Binding<Bool> { metricsPresentation ?? $localMetricsPresented }

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

    private var metricSearchLinks: [SearchLink] {
        guard showsMetrics else { return [] }
        var result: [SearchLink] = []
        if matchesMetricsPage {
            result.append(
                SearchLink(
                    id: "metrics-page", title: pageTitle("Metrics"), detail: nil,
                    symbol: "gauge.with.dots.needle.33percent", destination: .metrics))
        }
        result += matchingMetricServers.map {
            SearchLink(
                id: "metric-\($0.id)", title: $0.name, detail: nil,
                symbol: "gauge.with.dots.needle.33percent", destination: .metrics)
        }
        return result
    }

    private var hasSearchResults: Bool {
        !matchingHosts.isEmpty || !keychainSearchLinks.isEmpty || !snippetSearchLinks.isEmpty
            || !knownHostSearchLinks.isEmpty || !metricSearchLinks.isEmpty
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
        .navigationDestination(isPresented: presentsMetrics) { MobileMetricsView(app: app) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Host", systemImage: "server.rack") { editingHost = Host(name: "", host: "") }
                    Button("New Group", systemImage: "folder.badge.plus") { addingGroup = true }
                } label: {
                    Label("Add", systemImage: "plus").labelStyle(.iconOnly)
                }
            }
        }
        .sheet(item: $editingHost) { MobileHostEditor(app: app, host: $0) }
        .sheet(isPresented: $addingGroup) {
            MobileEditorSheet(
                title: String(localized: "New Group"), isDirty: !groupName.isEmpty,
                canSave: !groupName.isEmpty, compact: true,
                save: {
                    app.library.upsert(HostGroup(name: groupName))
                    if let error = app.library.storageError { throw MobileEditorError.message(error) }
                    groupName = ""
                }
            ) { TextField("Name", text: $groupName.singleLineText, axis: .horizontal).singleLinePaste().lineLimit(1) }
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
        if showsMetrics {
            MobileVaultLinkGroup {
                Button {
                    presentsMetrics.wrappedValue = true
                } label: {
                    MobileVaultLinkLabel(
                        title: Text("Metrics"), detail: nil, symbol: "gauge.with.dots.needle.33percent")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mobile.vault.metrics")
            }
        }
        MobileVaultLinkGroup {
            vaultLink("Keychain", symbol: "key") {
                MobileCredentialsView(app: app)
                    .mobileReviewPage("vault.keychain", scene: reviewScene)
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
                        presentsMetrics.wrappedValue = true
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
        case .snippets(let useQuery):
            MobileSnippetsView(
                app: app, initialQuery: useQuery ? query : "", execute: executeSnippet
            )
            .mobileReviewPage("vault.snippets", scene: reviewScene)
        case .knownHosts(let useQuery):
            MobileKnownHostsView(app: app, initialQuery: useQuery ? query : "")
                .mobileReviewPage("vault.knownHosts", scene: reviewScene)
        case .metrics:
            MobileMetricsView(app: app)
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
        }
        .accessibilityElement(children: .contain)
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
                        Text(app.library.loginAddress(for: host)).font(.caption.monospaced())
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 6) {
                    if app.library.knownHosts(for: host).contains(where: \.isMismatched) {
                        MobileCardChip(
                            title: "Host key changed", symbol: "exclamationmark.shield", tint: .orange)
                    }
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
            Button("SSH", systemImage: "terminal") { open(host.id, .ssh) }
            Button("SFTP", systemImage: "folder") { open(host.id, .sftp) }
            Button("Edit", systemImage: "pencil") { editingHost = host }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { deletingHost = host }
        }
    }
}
