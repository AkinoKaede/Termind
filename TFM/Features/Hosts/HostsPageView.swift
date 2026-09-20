import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

@Observable
final class HostsPageState {
    enum ConfirmationRoute: Identifiable {
        case deleteGroup(HostGroup)

        var id: String {
            switch self {
            case .deleteGroup(let group): "delete-group-\(group.id)"
            }
        }
    }

    var query = ""
    var selectedGroupID: HostGroup.ID?
    /// Which tags the grid is narrowed to, ticked in the titlebar search
    /// field's magnifier menu. Several at once means "carries all of these".
    var selectedTags: Set<String> = []
    var confirmation: ConfirmationRoute?

    /// Drops filters for tags no host carries any more.
    ///
    /// There is no tag registry to delete from — `HostLibraryModel.hostTags` is
    /// derived from the hosts themselves — so a tag disappears the moment its
    /// last host loses it. Without this the page would sit filtered by a tag
    /// that matches nothing, showing an empty grid and no obvious way back.
    func pruneSelectedTags(against available: [String]) {
        let live = Set(available)
        guard !selectedTags.isSubset(of: live) else { return }
        selectedTags.formIntersection(live)
    }
}

/// Every saved host, as a grid of cards grouped the way the user filed them.
///
/// This page is where the detail that used to crowd the sidebar now lives. The
/// layout follows Rayon: sections of cards rather than a sortable table, because
/// picking a machine is recognition — color, name, status dot — not a sorting
/// problem. Groups are the sections, so the hierarchy the user built in the host
/// editor is the hierarchy they see here.
///
/// Selecting cards updates the Hosts page's ordered Vault selection, which
/// the Details tab and this page's own Connect and Edit buttons read. Double-click
/// connects. Nothing outside this page acts on that selection — ⌘T raises the
/// host chooser rather than reusing whatever is highlighted here.
struct HostsPageView: ManagedCardPage {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    let state: HostsPageState

    init(state: HostsPageState = HostsPageState()) {
        self.state = state
    }
    /// A plain click replaces the window-scoped selection; Shift-click and a
    /// background marquee extend it. Keeping it on `WindowModel` lets the page
    /// restore the same cards when its workspace becomes current again.
    private var hostSelection: Set<Host.ID> {
        Set(
            window.vaultSelection(for: .hosts).compactMap { detail in
                detail.hostID
            })
    }
    /// Tags the list is narrowed to. Several at once means "carries all of
    /// these" — see `Host.hasTags`.

    // MARK: - Sections

    private var isFiltering: Bool { !state.query.isEmpty || !state.selectedTags.isEmpty }

    /// Filtering collapses the grouping into one "Results" section: when you are
    /// hunting for a name, being told which folder it sits in is noise. Tags
    /// narrow the same way — and stack with the field, so `prod` plus "web"
    /// means both.
    private var sections: [HostLibrarySection] {
        HostLibrarySectionLayout.sections(
            library: app.hostLibrary,
            query: state.query,
            selectedTags: state.selectedTags
        )
    }

    // MARK: - Page

    var managedSections: [ManagedCardSection<HostLibrarySection.ID, Host>] {
        sections.map { section in
            ManagedCardSection(
                id: section.id, title: section.title, items: section.hosts,
                isExpanded: section.isExpanded,
                canAcceptDrop: section.id != .results
            )
        }
    }

    var managedSelection: ManagedCardSelection<Host.ID> {
        ManagedCardSelection(selected: { hostSelection }, update: setHostSelection)
    }

    var managedCapabilities: ManagedCardCapabilities<HostLibrarySection.ID, Host.ID> {
        ManagedCardCapabilities(
            selection: .multiple,
            marqueeSelection: true,
            reordering: ManagedCardReordering(
                isEnabled: !isFiltering,
                dropPolicy: .anySection
            ) { ids, destination, next in
                app.hostLibrary.move(hostIDs: ids, into: destination.groupID, before: next)
            }
        )
    }

    var isManagedSourceEmpty: Bool {
        app.hostLibrary.hosts.isEmpty && app.hostLibrary.groups.isEmpty
    }

    @ViewBuilder
    func managedHeader(
        for section: ManagedCardSection<HostLibrarySection.ID, Host>, isDropTarget: Bool
    ) -> some View {
        if case .group(let groupID) = section.id, let group = app.hostLibrary.group(groupID) {
            let isExpanded = app.hostLibrary.isHostGroupExpanded(group.id)
            CardSectionHeader(
                title: section.title,
                count: section.items.count,
                toggle: { app.hostLibrary.setExpanded(!isExpanded, for: group.id) },
                isCollapsed: !isExpanded,
                select: { selectGroup(group.id) },
                isSelected: state.selectedGroupID == group.id,
                isDropTarget: isDropTarget
            )
            .contextMenu {
                Button("New Host", systemImage: MenuSymbol.newHost) {
                    openHostEditor(nil, groupID: group.id)
                }
                Button("New Subgroup", systemImage: MenuSymbol.newGroup) {
                    openWork(.hostGroupEditor(groupID: nil, parentID: group.id))
                }
                Button("Edit", systemImage: MenuSymbol.edit) { editGroup(group) }
                Divider()
                DestructiveMenuButton("Delete Group") { requestDelete(group) }
            }
        } else {
            CardSectionHeader(
                title: section.title,
                count: section.items.count,
                toggle: section.isExpanded.map { expanded in
                    { app.hostLibrary.setUngroupedExpanded(!expanded) }
                },
                isCollapsed: !(section.isExpanded ?? true),
                isDropTarget: isDropTarget
            )
        }
    }

    @ViewBuilder
    func managedCard(
        for host: Host, context: ManagedCardItemContext<Host>
    ) -> some View {
        HostCard(
            host: host,
            isSelected: context.isSelected,
            select: context.select,
            extendSelection: context.extendSelection,
            actionHosts: context.actionItems,
            selectionDeleted: pruneHostSelection
        )
    }

    func managedGhost(for host: Host) -> some View {
        HostGhostCard(host: host, address: app.hostLibrary.loginAddress(for: host))
    }

    /// The canvas beside the cards, which is where New Host, New Group and the
    /// tag filter live now that the dashed tiles and the page toolbar are gone.
    /// Right-clicking inside a group files the new host there without a second
    /// decision.
    func managedBlankAreaMenu(for section: HostLibrarySection.ID?) -> [NativeMenuEntry] {
        let groupID = section?.groupID
        return [
            NativeMenuEntry(title: String(localized: "New Host"), symbol: MenuSymbol.newHost) {
                openHostEditor(nil, groupID: groupID)
            },
            NativeMenuEntry(title: String(localized: "New Group"), symbol: MenuSymbol.newGroup) {
                openWork(.hostGroupEditor(groupID: nil, parentID: groupID))
            },
            .separator,
            tagFilterMenu,
            .separator,
            NativeMenuEntry(title: String(localized: "Import .ssh Folder"), symbol: MenuSymbol.importItem) {
                openWork(.sshImport(knownHostsOnly: false))
            },
        ]
    }

    /// Every tag in use, each one a toggle, plus a way out.
    ///
    /// There is no Delete Tag, and no tag registry behind this either:
    /// `HostLibraryModel.hostTags` is derived from the hosts themselves, so a
    /// tag stops being offered the moment its last host stops carrying it.
    private var tagFilterMenu: NativeMenuEntry {
        let tags = app.hostLibrary.hostTags
        var children = tags.map { tag in
            NativeMenuEntry(title: tag, isOn: state.selectedTags.contains(tag)) {
                if state.selectedTags.contains(tag) {
                    state.selectedTags.remove(tag)
                } else {
                    state.selectedTags.insert(tag)
                }
            }
        }
        if !tags.isEmpty {
            children.append(.separator)
            children.append(
                NativeMenuEntry(
                    title: String(localized: "Clear Filter"),
                    symbol: MenuSymbol.clearFilter,
                    isEnabled: !state.selectedTags.isEmpty
                ) { state.selectedTags.removeAll() }
            )
        }
        // The tags themselves stay bare: they are data rather than verbs, and
        // `isOn` already claims the column beside them.
        return NativeMenuEntry(
            title: String(localized: "Filter by Tag"),
            symbol: MenuSymbol.filterByTag,
            isEnabled: !tags.isEmpty,
            children: children
        )
    }

    // MARK: - Deleting a group

    /// Only asks when there is something to ask about. A group with no machines
    /// anywhere beneath it takes nothing with it but empty folders, and a dialog
    /// for that is a dialog people learn to dismiss without reading.
    private func requestDelete(_ group: HostGroup) {
        if app.hostLibrary.hosts(inTreeOf: group.id).isEmpty {
            delete(group, keepHosts: false)
        } else {
            state.confirmation = .deleteGroup(group)
        }
    }

    private func delete(_ group: HostGroup, keepHosts: Bool) {
        app.deleteHostGroup(group.id, keepHosts: keepHosts)
        state.confirmation = nil
        pruneHostSelection()

        if state.selectedGroupID == group.id { state.selectedGroupID = nil }
        window.pruneVaultSelections(in: app.hostLibrary)
    }

    private func deletionMessage(for group: HostGroup) -> String {
        let hosts = app.hostLibrary.hosts(inTreeOf: group.id).count
        let nested = app.hostLibrary.descendantGroups(of: group.id).count
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

    // MARK: - Host selection

    private var visibleHosts: [Host] {
        sections.flatMap(\.hosts)
    }

    private func setHostSelection(_ ids: Set<Host.ID>) {
        let valid = ids.intersection(Set(app.hostLibrary.hosts.map(\.id)))
        state.selectedGroupID = nil
        let ordered = visibleHosts.filter { valid.contains($0.id) }.map { VaultSelectionID.host($0.id) }
        window.setVaultSelection(ordered, for: .hosts)
    }

    private func selectGroup(_ id: HostGroup.ID) {
        window.clearVaultSelection(for: .hosts)
        state.selectedGroupID = id
    }

    private func pruneHostSelection() {
        setHostSelection(hostSelection)
    }

    // MARK: - Chrome

    func managedEmptyState() -> some View {
        ContentUnavailableView {
            Label("No Hosts", systemImage: "server.rack")
        } description: {
            Text("Save a host here, or enter ssh user@host on the Welcome page to connect once.")
        } actions: {
            Button("New Host") { openHostEditor(nil) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    func managedNoResultsState() -> some View {
        if state.query.isEmpty {
            ContentUnavailableView {
                Label("No Matching Hosts", systemImage: "tag")
            } description: {
                Text("No hosts have all selected tags.")
            } actions: {
                Button("Clear Filter") { state.selectedTags.removeAll() }
            }
        } else {
            ContentUnavailableView.search(text: state.query)
        }
    }

    var managedPresentation: HostsPagePresentation {
        HostsPagePresentation(
            state: state,
            liveTags: app.hostLibrary.hostTags,
            actions: HostsPagePresentation.Actions(
                deleteGroup: { delete($0, keepHosts: $1) },
                deletionMessage: deletionMessage
            )
        )
    }

    private func editGroup(_ group: HostGroup) {
        openWork(.hostGroupEditor(groupID: group.id, parentID: group.parentID))
    }

    private func openHostEditor(_ host: Host?, groupID: HostGroup.ID? = nil) {
        window.openHostEditor(host: host, groupID: groupID)
    }

    private func openWork(_ route: VaultWorkRoute) {
        window.openVaultWork(route, on: .hosts)
    }
}

struct HostsPagePresentation: ManagedCardPresentationModifier {
    struct Actions {
        let deleteGroup: (HostGroup, Bool) -> Void
        let deletionMessage: (HostGroup) -> String
    }

    let state: HostsPageState
    /// Tags at least one host still carries — see `HostsPageState.pruneSelectedTags`.
    let liveTags: [String]
    let actions: Actions

    func body(content: Content) -> some View {
        @Bindable var state = state
        content
            .onChange(of: liveTags, initial: true) { _, tags in
                state.pruneSelectedTags(against: tags)
            }
            .confirmationDialog(
                confirmationTitle,
                isPresented: Binding(
                    get: { state.confirmation != nil },
                    set: { if !$0 { state.confirmation = nil } }
                )
            ) {
                switch state.confirmation {
                case .deleteGroup(let group):
                    Button("Delete Group and Hosts", role: .destructive) {
                        actions.deleteGroup(group, false)
                    }
                    Button("Keep Hosts") { actions.deleteGroup(group, true) }
                case nil:
                    EmptyView()
                }
                Button("Cancel", role: .cancel) { state.confirmation = nil }
            } message: {
                confirmationMessage
            }
    }

    private var confirmationTitle: Text {
        switch state.confirmation {
        case .deleteGroup(let group): Text("Delete “\(group.name)”?")
        case nil: Text("")
        }
    }

    private var confirmationMessage: Text {
        switch state.confirmation {
        case .deleteGroup(let group): Text(actions.deletionMessage(group))
        case nil: Text("")
        }
    }
}

// MARK: - Card

private struct HostCard: View {
    @Environment(\.locale) private var locale
    @State private var clearHistoryHostIDs: [Host.ID]?

    let host: Host
    let isSelected: Bool
    let select: () -> Void
    let extendSelection: () -> Void
    let actionHosts: [Host]
    let selectionDeleted: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    private var status: ConnectionStatus { app.hostLibrary.status(of: host.id) }

    /// A pinned key that stopped matching. Shown here, on the host, because that
    /// is what the fingerprint belongs to — there is no separate Known Hosts
    /// list to go and check.
    private var keyMismatched: Bool {
        app.hostLibrary.knownHosts(for: host).contains(where: \.isMismatched)
    }

    var body: some View {
        card.clearAllHostHistoryConfirmation(hostIDs: $clearHistoryHostIDs)
    }

    private var card: some View {
        CardTile(
            selectionID: host.id,
            isSelected: isSelected,
            select: select,
            extendSelection: extendSelection,
            activate: quickConnect,
            activatesOnReturn: true
        ) {
            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                header
                footer
            }
        }
        .contextMenu {
            HostContextMenu(
                hosts: actionHosts,
                selectionDeleted: selectionDeleted,
                requestClearAllHistory: { clearHistoryHostIDs = $0 }
            )
        }
        .help(Text("\(app.hostLibrary.loginAddress(for: host)) — \(status.label)"))
        .accessibilityLabel(host.name)
        .accessibilityHint("Quick Connect with SSH")
        .accessibilityAction(named: Text("Quick Connect"), quickConnect)
    }

    private func quickConnect() {
        app.open(actionHosts, as: .sshSession, in: window)
    }

    private var header: some View {
        HStack(spacing: Metrics.Space.m) {
            HostDistributionIcon(host: host)

            VStack(alignment: .leading, spacing: 1) {
                Text(host.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(app.hostLibrary.loginAddress(for: host))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Metrics.Space.xs)

            StatusDot(status: status)
        }
    }

    private var footer: some View {
        HStack(spacing: Metrics.Space.xs) {
            if keyMismatched {
                CardChip(
                    text: String(localized: "Host key changed"),
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }
            ForEach(host.tags.prefix(2), id: \.self) { tag in
                CardChip(text: tag)
            }

            Spacer(minLength: Metrics.Space.xs)

            Text(
                app.lastConnectedAt(for: host.id)
                    .map { $0.formatted(.relative(presentation: .numeric).locale(locale)) }
                    ?? String(localized: "Never")
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
    }
}

/// The exact card-shaped slot the dragged batch will occupy. It lives in the
/// adaptive grid, so neighbouring cards reflow around the preview instead of an
/// overlay merely pointing at a position that has not opened yet.
private struct HostGhostCard: View {
    let host: Host
    let address: String

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            HStack(spacing: Metrics.Space.m) {
                HostDistributionIcon(host: host)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(address)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Metrics.Space.xs)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.Space.l)
        .frame(minHeight: Metrics.Card.minHeight, alignment: .top)
        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: Metrics.Radius.large))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.large)
                .strokeBorder(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

private struct HostDistributionIcon: View {
    let host: Host

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let entry = LinuxDistributionIconCatalog.entry(for: host.detectedDistribution)
        let brand = entry.flatMap {
            LinuxDistributionBrandColor.color(hex: $0.hex, colorScheme: colorScheme)
        }
        let tint = host.colorTag.color ?? brand ?? TermindColor.accent
        if let entry {
            CardIcon(asset: entry.asset, tint: tint)
        } else {
            CardIcon(symbol: "server.rack", tint: tint)
        }
    }
}
