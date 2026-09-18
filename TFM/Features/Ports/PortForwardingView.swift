import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure

@Observable
final class PortForwardingPageState {
    var query = ""
    var deleting: Set<UUID> = []
    var error: String?
}

struct PortForwardingPageView: ManagedCardPage {
    typealias SectionID = String
    typealias Item = PortForwardingRule
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    let state: PortForwardingPageState

    var managedSections: [ManagedCardSection<String, PortForwardingRule>] {
        [
            ManagedCardSection(
                id: "forwardings", title: String(localized: "Port Forwarding"),
                items: app.forwardings.search(state.query), canAcceptDrop: false, showsWhenEmpty: false)
        ]
    }
    var managedSelection: ManagedCardSelection<UUID> {
        ManagedCardSelection(
            selected: { Set(window.vaultSelection(for: .portForwarding).compactMap(\.forwardingID)) },
            update: { ids in
                window.setVaultSelection(
                    app.forwardings.rules.filter { ids.contains($0.id) }.map { .forwarding($0.id) },
                    for: .portForwarding)
            })
    }
    var managedCapabilities: ManagedCardCapabilities<String, UUID> {
        ManagedCardCapabilities(selection: .multiple, marqueeSelection: true)
    }
    var isManagedSourceEmpty: Bool { app.forwardings.rules.isEmpty }

    func managedHeader(for section: ManagedCardSection<String, Item>, isDropTarget: Bool) -> some View {
        CardSectionHeader(title: section.title, count: section.items.count)
    }
    func managedCard(for item: Item, context: ManagedCardItemContext<Item>) -> some View {
        card(item, selected: context.isSelected, select: context.select, extend: context.extendSelection)
            .contextMenu {
                if context.actionItems.count > 1 {
                    Button("Stop", systemImage: MenuSymbol.stop) {
                        app.forwarding.stop(
                            context.actionItems.filter { app.forwarding.state(for: $0.id).isActive }.map(\.id))
                    }
                    .disabled(!context.actionItems.contains { app.forwarding.state(for: $0.id).isActive })
                } else {
                    if app.forwarding.state(for: item.id).isActive {
                        Button("Stop", systemImage: MenuSymbol.stop) { app.forwarding.stop(item.id) }
                    } else {
                        Button(
                            app.forwarding.state(for: item.id).isFailed ? "Retry" : "Start",
                            systemImage: MenuSymbol.start
                        ) { start(item) }.disabled(!canStart(item))
                    }
                    Button("Edit", systemImage: MenuSymbol.edit) { open(item) }
                    Button("Duplicate", systemImage: MenuSymbol.duplicate) { duplicate(item) }
                    Button("Copy Address", systemImage: MenuSymbol.copy) { copyToPasteboard(item.bindAddress) }
                    Button("Copy SSH Command") {
                        if let command = app.forwardings.sshCommand(for: item) { copyToPasteboard(command) }
                    }.disabled(app.forwardings.sshCommand(for: item) == nil)
                }
                Divider()
                Button("Delete", systemImage: MenuSymbol.delete, role: .destructive) {
                    state.deleting = Set(context.actionItems.map(\.id))
                }
            }
    }
    func managedGhost(for item: Item) -> some View { card(item, selected: false, select: {}, extend: {}) }
    func managedBlankAreaMenu(for section: String?) -> [NativeMenuEntry] {
        window.creationMenu(for: .portForwarding, locale: .current)
    }
    func managedEmptyState() -> some View {
        ContentUnavailableView {
            Label("No Port Forwarding", systemImage: "arrow.left.arrow.right")
        } description: {
            Text("Create a forwarding rule, then start it manually.")
        } actions: {
            Button("New Forwarding") { window.openVaultWork(.forwardingEditor(nil), on: .portForwarding) }
        }
    }
    func managedNoResultsState() -> some View { ContentUnavailableView.search(text: state.query) }
    var managedPresentation: PortForwardingPagePresentation {
        PortForwardingPagePresentation(
            state: state, ids: app.forwardings.rules.map(\.id),
            prune: { window.pruneVaultSelections(in: app.hostLibrary) },
            delete: {
                do { try app.forwardings.delete(state.deleting) } catch { state.error = error.localizedDescription }
                state.deleting = []
            })
    }

    private func card(_ rule: Item, selected: Bool, select: @escaping () -> Void, extend: @escaping () -> Void)
        -> some View
    {
        let runtime = app.forwarding.state(for: rule.id)
        let activate = {
            if app.forwarding.state(for: rule.id).isActive { app.forwarding.stop(rule.id) } else { start(rule) }
        }
        return CardTile(
            selectionID: rule.id, isSelected: selected,
            select: select, extendSelection: extend, activate: activate, activatesOnReturn: true
        ) {
            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                HStack {
                    CardIcon(symbol: rule.kind.symbol, tint: rule.colorTag.color ?? TermindColor.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rule.displayName(hostName: app.hostLibrary.host(rule.hostID)?.name))
                            .font(.headline).lineLimit(1)
                        Text(rule.summary).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: Metrics.Space.xs) {
                    CardChip(text: rule.kind.shortDisplayName)
                    Text(app.hostLibrary.host(rule.hostID)?.name ?? String(localized: "Host Unavailable"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    CardChip(
                        text: runtime.label, symbol: runtime.isActive ? "circle.fill" : "circle",
                        tint: runtime.isActive ? .green : nil)
                }
            }
        }
    }
    private func canStart(_ rule: Item) -> Bool {
        PortForwardingEditorPolicy(
            rule: nil, savedRule: rule, savedHost: app.hostLibrary.host(rule.hostID),
            isRuntimeActive: app.forwarding.state(for: rule.id).isActive
        ).canStart
    }
    private func open(_ rule: Item) { window.openVaultWork(.forwardingEditor(rule.id), on: .portForwarding) }
    private func start(_ rule: Item) {
        guard canStart(rule) else { return }
        open(rule)
        app.forwarding.start(rule.id)
    }
    private func duplicate(_ rule: Item) {
        var copy = rule
        copy.id = UUID()
        if !copy.label.isEmpty { copy.label += String(localized: " Copy") }
        do {
            try app.forwardings.save(copy)
            open(copy)
        } catch { state.error = error.localizedDescription }
    }
}

struct PortForwardingPagePresentation: ManagedCardPresentationModifier {
    @Bindable var state: PortForwardingPageState
    let ids: [UUID]
    let prune: () -> Void
    let delete: () -> Void
    func body(content: Content) -> some View {
        content.onAppear(perform: prune).onChange(of: ids) { prune() }
            .confirmationDialog(
                "Delete Forwarding Rules?",
                isPresented: Binding(get: { !state.deleting.isEmpty }, set: { if !$0 { state.deleting = [] } })
            ) {
                Button("Delete", role: .destructive, action: delete)
            }
            .alert(
                "Operation Failed",
                isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })
            ) {
                Button("OK") { state.error = nil }
            } message: {
                Text(state.error ?? "")
            }
    }
}

struct PortForwardingDetailView: View {
    let ruleID: UUID?
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = PortForwardingRule(hostID: UUID())
    @State private var loaded = false
    @State private var error: String?

    private var saved: PortForwardingRule? { ruleID.flatMap(app.forwardings.portForwarding) }
    private var runtime: PortForwardingRuntimeState { app.forwarding.state(for: draft.id) }
    private var normalized: PortForwardingRule? { PortForwardingEditorPolicy.normalized(draft) }
    private var canSave: Bool {
        !runtime.isActive && normalized != nil && app.hostLibrary.host(draft.hostID) != nil
            && (ruleID == nil || saved != nil)
    }

    var body: some View {
        VaultDetailScaffold(
            title: ruleID == nil
                ? "New Forwarding" : "\(draft.displayName(hostName: app.hostLibrary.host(draft.hostID)?.name))",
            symbol: "arrow.left.arrow.right", close: window.closeVaultWork
        ) {
            let context = app.forwarding.connection(for: draft.id)
            ZStack {
                if let context, context.journey.isPresented {
                    journey(context)
                } else {
                    Form {
                        if ruleID != nil {
                            Section {
                                LabeledContent("Status", value: runtime.label)
                                if runtime.isActive {
                                    Button("Stop") { app.forwarding.stop(draft.id) }
                                } else {
                                    Button(runtime.isFailed ? "Retry" : "Start") { app.forwarding.start(draft.id) }
                                        .disabled(saved == nil || normalized != saved || !canSave)
                                }
                            }
                        }
                        PortForwardingHostPicker(rule: $draft, hosts: app.forwardings.hosts)
                            .disabled(runtime.isActive)
                        PortForwardingFields(rule: $draft).disabled(runtime.isActive)
                        if let error { Text(error).foregroundStyle(.red) }
                        if ruleID != nil && saved == nil {
                            Text("The forwarding rule is unavailable.").foregroundStyle(.secondary)
                        }
                    }.formStyle(.grouped)
                        .transition(.opacity)
                }
            }
            .animation(Motion.panel(reduceMotion: reduceMotion), value: context?.journey.isPresented ?? false)
        } footer: {
            HStack {
                if runtime.isActive { Button("Stop") { app.forwarding.stop(draft.id) } }
                Spacer()
                Button("Close", action: window.closeVaultWork)
                Button("Save", action: save).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(!canSave)
            }.padding(Metrics.Space.l)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let saved { draft = saved }
        }
    }

    private func journey(_ context: PortForwardingConnection) -> some View {
        let promptID = context.authenticationPrompt?.id
        let hostKeyRequestID = context.hostKeyRequestID
        return ConnectionJourneyView(
            journey: context.journey, authenticationPrompt: context.authenticationPrompt,
            hostKey: context.connection.pendingHostKey,
            submitAuthentication: { identity, username, password, passphrase, key, save in
                guard let promptID else { return }
                app.forwarding.submitAuthentication(
                    for: draft.id, promptID: promptID, identityID: identity,
                    username: username, password: password, passphrase: passphrase, keyID: key, save: save)
            },
            continueHostKey: {
                guard let hostKeyRequestID else { return }
                app.forwarding.acceptHostKey(
                    for: draft.id, requestID: hostKeyRequestID, observation: $0, remember: false)
            },
            trustHostKey: {
                guard let hostKeyRequestID else { return }
                app.forwarding.acceptHostKey(
                    for: draft.id, requestID: hostKeyRequestID, observation: $0, remember: true)
            },
            denyHostKey: cancel, retry: { app.forwarding.retry(draft.id) }, cancel: cancel,
            keyboardAuthentication: context.connection.keyboardAuthentication, cancelKeyboardAuthentication: cancel,
            isEmbedded: true)
    }
    private func cancel() {
        app.forwarding.stop(draft.id)
        window.closeVaultWork()
    }
    private func save() {
        guard canSave, let normalized else { return }
        do {
            try app.forwardings.save(normalized)
            window.selectVaultItem(.forwarding(normalized.id), on: .portForwarding)
            window.openVaultWork(.forwardingEditor(normalized.id), on: .portForwarding)
            draft = normalized
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
