import SwiftUI

@Observable
final class HostsPageState {
    enum ConfirmationRoute: Identifiable {
        case deleteGroup(HostGroup)
        case deleteTag(String)

        var id: String {
            switch self {
            case .deleteGroup(let group): "delete-group-\(group.id)"
            case .deleteTag(let tag): "delete-tag-\(tag)"
            }
        }
    }

    var query = ""
    var selectedGroupID: HostGroup.ID?
    var selectedTags: Set<String> = []
    var confirmation: ConfirmationRoute?
}

/// Every saved host, as a grid of cards grouped the way the user filed them.
///
/// This page is where the detail that used to crowd the sidebar now lives. The
/// layout follows Rayon: sections of cards rather than a sortable table, because
/// picking a machine is recognition — color, name, status dot — not a sorting
/// problem. Groups are the sections, so the hierarchy the user built in the host
/// editor is the hierarchy they see here.
///
/// Selecting cards updates the Hosts page's ordered ContextPanel selection, which
/// the Details tab and this page's own Connect and Edit buttons read. Double-click
/// connects. Nothing outside this page acts on that selection — ⌘T raises the
/// host chooser rather than reusing whatever is highlighted here.
struct HostsPageView: ManagedCardPage {
    nonisolated enum SectionID: Hashable {
        case results
        case group(HostGroup.ID)
        case ungrouped

        var groupID: HostGroup.ID? {
            switch self {
            case .group(let id): id
            case .results, .ungrouped: nil
            }
        }
    }

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    let state: HostsPageState
    @FocusState private var searchFocused: Bool

    init(state: HostsPageState = HostsPageState()) {
        self.state = state
    }
    /// A plain click replaces the window-scoped selection; Shift-click and a
    /// background marquee extend it. Keeping it on `WindowModel` lets the page
    /// restore the same cards when its tab becomes current again.
    private var hostSelection: Set<Host.ID> {
        Set(
            window.detailSelection(for: .hosts).compactMap { detail in
                detail.hostID
            })
    }
    /// Tags the list is narrowed to. Several at once means "carries all of
    /// these" — see `Host.hasTags`.

    // MARK: - Sections

    private struct Section {
        let id: SectionID
        let title: String
        /// `nil` means the section cannot be folded at all — which is only
        /// Results, since folding away what you just searched for is not a thing
        /// anyone wants.
        var isExpanded: Bool?
        let hosts: [Host]
    }

    private var isFiltering: Bool { !state.query.isEmpty || !state.selectedTags.isEmpty }

    /// Filtering collapses the grouping into one "Results" section: when you are
    /// hunting for a name, being told which folder it sits in is noise. Tags
    /// narrow the same way — and stack with the field, so `prod` plus "web"
    /// means both.
    private var sections: [Section] {
        guard !isFiltering else {
            let matches = app.hosts.searchHosts(state.query).filter {
                $0.hasTags(state.selectedTags)
            }
            guard !matches.isEmpty else { return [] }
            return [Section(id: .results, title: String(localized: "Results"), hosts: matches)]
        }

        var result: [Section] = []

        // Nested groups are flattened into "Parent / Child" headers, so the tree
        // reads in a grid that has no room to indent.
        //
        // Collapsing a group therefore has to stop the recursion, not just hide
        // one grid: `Production / Edge` is a sibling row in this list, and
        // leaving it behind when Production folds would strand a child header
        // under a parent that is no longer showing anything.
        //
        // Empty groups get a header too, with a count of zero. This is the page
        // that creates groups, and one that vanished the moment it was made
        // would read as a button that did nothing.
        func walk(_ group: HostGroup, prefix: String) {
            let title = prefix.isEmpty ? group.name : "\(prefix) / \(group.name)"
            result.append(
                Section(
                    id: .group(group.id), title: title,
                    isExpanded: group.isExpanded,
                    hosts: app.hosts.hosts(in: group.id)
                )
            )
            guard group.isExpanded else { return }
            for child in app.hosts.childGroups(of: group.id) {
                walk(child, prefix: title)
            }
        }
        for group in app.hosts.rootGroups {
            walk(group, prefix: "")
        }

        let ungrouped = app.hosts.hosts(in: nil)
        if !ungrouped.isEmpty || !app.hosts.groups.isEmpty {
            // Foldable like a real group, because on a fleet that is mostly
            // unfiled it is the section most worth getting out of the way. Its
            // flag has to live on the store instead of on a `HostGroup` — there
            // is no group here to hang it on.
            result.append(
                Section(
                    id: .ungrouped, title: String(localized: "Ungrouped"),
                    isExpanded: app.hosts.isUngroupedExpanded, hosts: ungrouped
                )
            )
        }

        return result
    }

    // MARK: - Page

    var managedSections: [ManagedCardSection<SectionID, Host>] {
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

    var managedCapabilities: ManagedCardCapabilities<SectionID, Host.ID> {
        ManagedCardCapabilities(
            selection: .multiple,
            marqueeSelection: false,
            reordering: ManagedCardReordering(
                isEnabled: !isFiltering,
                dropPolicy: .anySection
            ) { ids, destination, next in
                app.hosts.move(hostIDs: ids, into: destination.groupID, before: next)
            }
        )
    }

    var isManagedSourceEmpty: Bool {
        app.hosts.hosts.isEmpty && app.hosts.groups.isEmpty
    }

    @ViewBuilder
    func managedHeader(
        for section: ManagedCardSection<SectionID, Host>, isDropTarget: Bool
    ) -> some View {
        if case .group(let groupID) = section.id, let group = app.hosts.group(groupID) {
            CardSectionHeader(
                title: section.title,
                count: section.items.count,
                toggle: { app.hosts.setExpanded(!group.isExpanded, for: group.id) },
                isCollapsed: !group.isExpanded,
                select: { selectGroup(group.id) },
                isSelected: state.selectedGroupID == group.id,
                isDropTarget: isDropTarget
            )
            .contextMenu {
                Button("Edit") { editGroup(group) }
                Divider()
                Button("Delete Group", role: .destructive) { requestDelete(group) }
            }
        } else {
            CardSectionHeader(
                title: section.title,
                count: section.items.count,
                toggle: section.isExpanded.map { expanded in
                    { app.hosts.setUngroupedExpanded(!expanded) }
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
        HostGhostCard(host: host, address: app.hosts.loginAddress(for: host))
    }

    @ViewBuilder
    func managedSupplementaryContent(for section: SectionID) -> some View {
        if section == .ungrouped || sections.count == 1 {
            AddCardTile(title: "New Host") {
                openHostEditor(nil)
            }
        }
    }

    // MARK: - Deleting a group

    /// Only asks when there is something to ask about. A group with no machines
    /// anywhere beneath it takes nothing with it but empty folders, and a dialog
    /// for that is a dialog people learn to dismiss without reading.
    private func requestDelete(_ group: HostGroup) {
        if app.hosts.hosts(inTreeOf: group.id).isEmpty {
            delete(group, keepHosts: false)
        } else {
            state.confirmation = .deleteGroup(group)
        }
    }

    private func delete(_ group: HostGroup, keepHosts: Bool) {
        app.hosts.delete(groupID: group.id, keepHosts: keepHosts)
        state.confirmation = nil
        pruneHostSelection()

        if state.selectedGroupID == group.id { state.selectedGroupID = nil }
        window.pruneDetailSelections(in: app.hosts)
    }

    /// A deleted tag also stops being something the list is narrowed by —
    /// otherwise the page would sit filtered by a tag no host has, showing
    /// nothing, with no obvious way back.
    private func deleteTag(_ tag: String) {
        app.hosts.deleteTag(tag)
        state.selectedTags.remove(tag)
        state.confirmation = nil
    }

    private func deletionMessage(for group: HostGroup) -> String {
        let hosts = app.hosts.hosts(inTreeOf: group.id).count
        let nested = app.hosts.descendantGroups(of: group.id).count
        let hostCount = hosts == 1
            ? String(localized: "1 host") : String(localized: "\(hosts) hosts")
        if nested == 0 {
            return String(localized: "This group contains \(hostCount).")
        }
        let groupCount = nested == 1
            ? String(localized: "1 nested group")
            : String(localized: "\(nested) nested groups")
        return String(localized: "This group contains \(hostCount) and \(groupCount). Nested groups will be deleted.")
    }

    // MARK: - Host selection

    private var visibleHosts: [Host] {
        sections.flatMap(\.hosts)
    }

    private var selectedHosts: [Host] {
        visibleHosts.filter { hostSelection.contains($0.id) }
    }

    private func setHostSelection(_ ids: Set<Host.ID>) {
        let valid = ids.intersection(Set(app.hosts.hosts.map(\.id)))
        if !valid.isEmpty { state.selectedGroupID = nil }
        let ordered = visibleHosts.filter { valid.contains($0.id) }.map { ContextPanelDetailID.host($0.id) }
        window.setDetailSelection(ordered, for: .hosts)
    }

    private func selectGroup(_ id: HostGroup.ID) {
        window.clearDetailSelection(for: .hosts)
        state.selectedGroupID = id
    }

    private func pruneHostSelection() {
        setHostSelection(hostSelection)
    }

    // MARK: - Chrome

    func managedToolbar() -> some View {
        PageToolbar(
            query: Binding(get: { state.query }, set: { state.query = $0 }),
            prompt: "Filter hosts",
            searchFocused: $searchFocused
        ) {
            TagFilterButton(
                tags: app.hosts.hostTags,
                selection: Binding(
                    get: { state.selectedTags }, set: { state.selectedTags = $0 }
                ),
                requestDelete: { state.confirmation = .deleteTag($0) }
            )
        } actions: {
            if !selectedHosts.isEmpty {
                if selectedHosts.count == 1 {
                    Button("Quick Connect") {
                        app.open(selectedHosts, as: .sshSession, in: window)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Menu("Quick Connect") {
                        Button("Separate Tabs") {
                            app.open(selectedHosts, as: .sshSession, in: window)
                        }
                        Button("One Workspace") {
                            app.open(
                                selectedHosts, as: .sshSession,
                                layout: .oneWorkspace, in: window
                            )
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderedProminent)
                }
                HostConnectMenu(hosts: selectedHosts)
                    .menuStyle(.button)
                if selectedHosts.count == 1, let host = selectedHosts.first {
                    Button("Edit") { openHostEditor(host) }
                }
            }
            // The same slot, for the other kind of selection — the two can never
            // both be set, so the toolbar only ever offers one set of verbs.
            if let group = state.selectedGroupID.flatMap({ app.hosts.group($0) }) {
                Button("Edit Group") { editGroup(group) }
                Button("Delete Group", role: .destructive) { requestDelete(group) }
            }
            // Groups are made here rather than only in the host editor: filing
            // is what this page is for, and a folder should not have to wait on
            // a host to exist.
            Button("New Group") {
                openWork(.hostGroupEditor(groupID: nil, parentID: nil))
            }
            Button("New Host") { openHostEditor(nil) }
        }
    }

    func managedEmptyState() -> some View {
        ContentUnavailableView {
            Label("No Hosts", systemImage: "server.rack")
        } description: {
            Text("Save a host here, or enter user@host on the Welcome page to connect once.")
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

    func managedFootnote() -> some View { EmptyView() }

    var managedPresentation: HostsPagePresentation {
        HostsPagePresentation(
            state: state,
            actions: HostsPagePresentation.Actions(
                store: app.hosts,
                deleteGroup: { delete($0, keepHosts: $1) },
                deleteTag: deleteTag,
                deletionMessage: deletionMessage
            )
        )
    }

    private func editGroup(_ group: HostGroup) {
        openWork(.hostGroupEditor(groupID: group.id, parentID: group.parentID))
    }

    private func openHostEditor(_ host: Host?) {
        window.openHostEditor(host: host)
        restoreSearchFocus()
    }

    private func openWork(_ route: VaultWorkRoute) {
        window.openVaultWork(route, on: .hosts)
        restoreSearchFocus()
    }

    private func restoreSearchFocus() {
        Task { @MainActor in
            await Task.yield()
            searchFocused = true
        }
    }
}

struct HostsPagePresentation: ManagedCardPresentationModifier {
    struct Actions {
        let store: HostStore
        let deleteGroup: (HostGroup, Bool) -> Void
        let deleteTag: (String) -> Void
        let deletionMessage: (HostGroup) -> String
    }

    let state: HostsPageState
    let actions: Actions

    func body(content: Content) -> some View {
        @Bindable var state = state
        content
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
                case .deleteTag(let tag):
                    Button("Delete Tag", role: .destructive) { actions.deleteTag(tag) }
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
        case .deleteGroup(let group): Text("Delete “\(group.name)”?" )
        case .deleteTag(let tag): Text("Delete tag “\(tag)”?" )
        case nil: Text("")
        }
    }

    private var confirmationMessage: Text {
        switch state.confirmation {
        case .deleteGroup(let group): Text(actions.deletionMessage(group))
        case .deleteTag(let tag):
            Text("Removes it from \(actions.store.hosts(taggedWith: tag).count) hosts. Snippet tags are unchanged.")
        case nil: Text("")
        }
    }
}

// MARK: - Card

private struct HostCard: View {
    let host: Host
    let isSelected: Bool
    let select: () -> Void
    let extendSelection: () -> Void
    let actionHosts: [Host]
    let selectionDeleted: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    private var status: ConnectionStatus { app.hosts.status(of: host.id) }

    /// A pinned key that stopped matching. Shown here, on the host, because that
    /// is what the fingerprint belongs to — there is no separate Known Hosts
    /// list to go and check.
    private var keyMismatched: Bool {
        app.hosts.knownHosts(for: host).contains(where: \.isMismatched)
    }

    var body: some View { card }

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
            HostContextMenu(hosts: actionHosts, selectionDeleted: selectionDeleted)
        }
        .help(Text("\(app.hosts.loginAddress(for: host)) — \(status.label)"))
        .accessibilityLabel(host.name)
        .accessibilityHint("Quick Connect with SSH")
        .accessibilityAction(named: Text("Quick Connect"), quickConnect)
    }

    private func quickConnect() {
        app.open(actionHosts, as: .sshSession, in: window)
    }

    private var header: some View {
        HStack(spacing: Metrics.Space.m) {
            CardIcon(symbol: "server.rack", tint: host.colorTag.color ?? .accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(host.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(app.hosts.loginAddress(for: host))
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
                host.lastUsedAt
                    .map { $0.formatted(.relative(presentation: .numeric)) }
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
                CardIcon(symbol: "server.rack", tint: host.colorTag.color ?? .accentColor)
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
