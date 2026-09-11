import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

struct MobileVaultView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    let app: MobileAppModel
    let open: (UUID, MobileWorkspaceDescriptor.Kind) -> Void
    let executeSnippet: (Snippet, [Host.ID]) -> Void
    @State private var query = ""
    @State private var editingHost: Host?
    @State private var deletingHost: Host?
    @State private var groupName = ""
    @State private var addingGroup = false

    init(
        app: MobileAppModel,
        open: @escaping (UUID, MobileWorkspaceDescriptor.Kind) -> Void,
        executeSnippet: @escaping (Snippet, [Host.ID]) -> Void = { _, _ in }
    ) {
        self.app = app
        self.open = open
        self.executeSnippet = executeSnippet
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

    private var hasSearchResults: Bool {
        !matchingHosts.isEmpty || !matchingKeys.isEmpty || !matchingIdentities.isEmpty
            || !matchingSnippets.isEmpty || !matchingKnownHosts.isEmpty || !matchingMetricServers.isEmpty
            || matchesMetricsPage || matchesKeychainPage || matchesSnippetsPage || matchesKnownHostsPage
    }

    var body: some View {
        List {
            if query.isEmpty {
                Section {
                    NavigationLink {
                        MobileMetricsView(app: app)
                    } label: {
                        Label("Metrics", systemImage: "gauge.with.dots.needle.33percent")
                    }
                }
                Section {
                    NavigationLink {
                        MobileCredentialsView(app: app)
                    } label: {
                        Label("Keychain", systemImage: "key")
                    }
                    NavigationLink {
                        MobileSnippetsView(app: app, execute: executeSnippet)
                    } label: {
                        Label("Snippets", systemImage: "curlybraces")
                    }
                    NavigationLink {
                        MobileKnownHostsView(app: app)
                    } label: {
                        Label("Known Hosts", systemImage: "touchid")
                    }
                }
                if app.library.hosts.isEmpty {
                    ContentUnavailableView(
                        "No Hosts", systemImage: "server.rack",
                        description: Text("Add a host to connect with SSH or SFTP.")
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                ForEach(app.library.groups) { group in
                    let hosts = matchingHosts.filter { $0.groupID == group.id }
                    Section {
                        MobileCardGrid { ForEach(hosts) { row($0) } }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } header: {
                        HStack(spacing: 8) {
                            Text(group.name)
                            Text(hosts.count, format: .number).font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                let ungrouped = matchingHosts.filter { $0.groupID == nil }
                if !ungrouped.isEmpty {
                    Section {
                        MobileCardGrid { ForEach(ungrouped) { row($0) } }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } header: {
                        HStack(spacing: 8) {
                            Text("Hosts")
                            Text(ungrouped.count, format: .number).font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                searchResults
            }
        }
        .searchable(text: $query)
        .navigationTitle("Vault")
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
            ) { TextField("Name", text: $groupName) }
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
    }

    @ViewBuilder
    private var searchResults: some View {
        if !hasSearchResults {
            ContentUnavailableView.search(text: query)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        if !matchingHosts.isEmpty {
            Section("Hosts") {
                MobileCardGrid { ForEach(matchingHosts) { row($0) } }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        if matchesKeychainPage || !matchingKeys.isEmpty || !matchingIdentities.isEmpty {
            Section("Keychain") {
                if matchesKeychainPage {
                    NavigationLink {
                        MobileCredentialsView(app: app)
                    } label: {
                        Label("Keychain", systemImage: "key")
                    }
                }
                ForEach(matchingKeys) { key in
                    NavigationLink {
                        MobileCredentialsView(app: app, initialQuery: query)
                    } label: {
                        searchResultLabel(key.label, detail: key.fingerprint, symbol: "key")
                    }
                }
                ForEach(matchingIdentities) { identity in
                    NavigationLink {
                        MobileCredentialsView(app: app, initialQuery: query)
                    } label: {
                        searchResultLabel(
                            identity.name.isEmpty ? identity.username : identity.name,
                            detail: identity.username,
                            symbol: "person.crop.square"
                        )
                    }
                }
            }
        }
        if matchesSnippetsPage || !matchingSnippets.isEmpty {
            Section("Snippets") {
                if matchesSnippetsPage {
                    NavigationLink {
                        MobileSnippetsView(app: app, execute: executeSnippet)
                    } label: {
                        Label("Snippets", systemImage: "curlybraces")
                    }
                }
                ForEach(matchingSnippets) { snippet in
                    NavigationLink {
                        MobileSnippetsView(app: app, initialQuery: query, execute: executeSnippet)
                    } label: {
                        searchResultLabel(snippet.title, detail: snippet.body, symbol: "curlybraces")
                    }
                }
            }
        }
        if matchesKnownHostsPage || !matchingKnownHosts.isEmpty {
            Section("Known Hosts") {
                if matchesKnownHostsPage {
                    NavigationLink {
                        MobileKnownHostsView(app: app)
                    } label: {
                        Label("Known Hosts", systemImage: "touchid")
                    }
                }
                ForEach(matchingKnownHosts) { entry in
                    NavigationLink {
                        MobileKnownHostsView(app: app, initialQuery: query)
                    } label: {
                        Label(entry.displayAddress, systemImage: "touchid")
                    }
                }
            }
        }
        if matchesMetricsPage || !matchingMetricServers.isEmpty {
            Section("Metrics") {
                if matchesMetricsPage {
                    NavigationLink {
                        MobileMetricsView(app: app)
                    } label: {
                        Label("Metrics", systemImage: "gauge.with.dots.needle.33percent")
                    }
                }
                ForEach(matchingMetricServers) { server in
                    NavigationLink {
                        MobileMetricsView(app: app)
                    } label: {
                        Label(server.name, systemImage: "gauge.with.dots.needle.33percent")
                    }
                }
            }
        }
    }

    private func searchResultLabel(_ title: String, detail: String, symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } icon: {
            Image(systemName: symbol)
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
            open(host.id, .ssh)
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
            .accessibilityHint("Quick Connect with SSH")
        } actions: {
            Button("SSH", systemImage: "terminal") { open(host.id, .ssh) }
            Button("SFTP", systemImage: "folder") { open(host.id, .sftp) }
            Button("Edit", systemImage: "pencil") { editingHost = host }
            Button("Delete", systemImage: "trash", role: .destructive) { deletingHost = host }
        }
    }
}
