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
    @Environment(VaultWorkEditingSession.self) private var editingSession
    @Bindable var state: PortForwardingPageState

    var managedSections: [ManagedCardSection<String, PortForwardingRule>] {
        [
            ManagedCardSection(
                id: "forwardings", title: String(localized: AppStrings.Navigation.portForwarding),
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
        card(
            item, selected: context.isSelected,
            select: { select(item, action: context.select) }, extend: context.extendSelection
        )
        .contextMenu {
            if context.actionItems.count > 1 {
                Button(AppStrings.Common.stop.swiftUIKey, systemImage: MenuSymbol.stop) {
                    app.forwarding.stop(
                        context.actionItems.filter { app.forwarding.state(for: $0.id).isActive }.map(\.id))
                }
                .disabled(!context.actionItems.contains { app.forwarding.state(for: $0.id).isActive })
            } else {
                if app.forwarding.state(for: item.id).isActive {
                    Button(AppStrings.Common.stop.swiftUIKey, systemImage: MenuSymbol.stop) {
                        app.forwarding.stop(item.id)
                    }
                } else {
                    Button(
                        app.forwarding.state(for: item.id).isFailed
                            ? AppStrings.Common.retry.swiftUIKey : AppStrings.Forwarding.start.swiftUIKey,
                        systemImage: MenuSymbol.start
                    ) { start(item) }.disabled(!canStart(item))
                }
                Menu(AppStrings.Common.copy.swiftUIKey, systemImage: MenuSymbol.copy) {
                    Button(AppStrings.Forwarding.address.swiftUIKey, systemImage: MenuSymbol.copy) {
                        copyToPasteboard(item.bindAddress)
                    }
                    Button(AppStrings.Vault.sshCommand.swiftUIKey, systemImage: MenuSymbol.ssh) {
                        if let command = app.forwardings.sshCommand(for: item) {
                            copyToPasteboard(command)
                        }
                    }
                    .disabled(app.forwardings.sshCommand(for: item) == nil)
                }
                Divider()
                Button(AppStrings.Common.edit.swiftUIKey, systemImage: MenuSymbol.edit) { open(item) }
                Button(AppStrings.Common.duplicate.swiftUIKey, systemImage: MenuSymbol.duplicate) { duplicate(item) }
            }
            Divider()
            DestructiveMenuButton(AppStrings.Common.delete) {
                state.deleting = Set(context.actionItems.map(\.id))
            }
        }
    }
    func managedGhost(for item: Item) -> some View { card(item, selected: false, select: {}, extend: {}) }
    func managedBlankAreaMenu(for section: String?) -> [NativeMenuEntry] {
        window.creationMenu(for: .portForwarding, locale: .current)
    }
    func managedBlankAreaPrimaryAction() {
        guard let route = window.vaultWorkRoute, case .forwardingEditor = route else { return }
        editingSession.requestTransition(route: route, action: window.closeVaultWork)
    }
    func managedEmptyState() -> some View {
        ContentUnavailableView {
            Label(AppStrings.Forwarding.noPortForwarding.swiftUIKey, systemImage: "arrow.left.arrow.right")
        } description: {
            Text(AppStrings.Forwarding.createAForwardingRuleThenStartItManually)
        } actions: {
            Button(AppStrings.Forwarding.newForwarding.swiftUIKey) {
                window.openVaultWork(.forwardingEditor(nil), on: .portForwarding)
            }
        }
    }
    func managedNoResultsState() -> some View { ContentUnavailableView.search(text: state.query) }
    var managedPresentation: ManagedCardDeletionPresentation<UUID> {
        ManagedCardDeletionPresentation(
            deleting: $state.deleting, error: $state.error, ids: app.forwardings.rules.map(\.id),
            confirmationTitle: deletionTitle, errorTitle: AppStrings.Common.operationFailed,
            explanation: deletionExplanation,
            prune: { window.pruneVaultSelections(in: app.hostLibrary) },
            delete: {
                do { try app.forwardings.delete(state.deleting) } catch { state.error = error.localizedDescription }
                state.deleting = []
            })
    }

    private var deletionTitle: LocalizedStringResource {
        state.deleting.count == 1
            ? AppStrings.Forwarding.deleteForwardingRuleConfirmation
            : AppStrings.Forwarding.deleteForwardingRulesConfirmationNamed(state.deleting.count)
    }

    private var deletionExplanation: Text {
        state.deleting.count == 1
            ? Text(AppStrings.Forwarding.anyActiveForwardingSessionForThisRuleWillBeStopped)
            : Text(AppStrings.Forwarding.deleteActiveRulesWarning)
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
                    Text(
                        app.hostLibrary.host(rule.hostID)?.name
                            ?? String(localized: AppStrings.Forwarding.hostUnavailable)
                    )
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    CardChip(
                        text: runtime.compactLabel, symbol: runtime.isActive ? "circle.fill" : "circle",
                        tint: runtime.isActive ? .green : nil)
                }
            }
        }
    }
    private func canStart(_ rule: Item) -> Bool {
        PortForwardingEditorPolicy.canStart(
            rule.id, savedRule: rule, savedHost: app.hostLibrary.host(rule.hostID),
            isRuntimeActive: app.forwarding.state(for: rule.id).isActive)
    }
    private func select(_ rule: Item, action: @escaping () -> Void) {
        guard let route = window.vaultWorkRoute, case .forwardingEditor(let editingID) = route else {
            action()
            return
        }
        guard editingID != rule.id else {
            action()
            return
        }
        editingSession.requestTransition(route: route) {
            action()
            open(rule)
        }
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
        if !copy.label.isEmpty { copy.label += String(localized: AppStrings.Common.copySuffix) }
        do {
            open(try app.forwardings.save(copy))
        } catch { state.error = error.localizedDescription }
    }
}

struct PortForwardingDetailView: View {
    let ruleID: UUID?
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(VaultWorkEditingSession.self) private var editingSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft: PortForwardingRule
    @State private var original: PortForwardingRule
    @State private var loaded = false
    @State private var error: String?
    @State private var deletionError: String?
    @State private var confirmsDeletion = false
    @State private var editingToken: UUID?

    init(ruleID: UUID?) {
        self.ruleID = ruleID
        let initial = PortForwardingRule(hostID: UUID())
        _draft = State(initialValue: initial)
        _original = State(initialValue: initial)
    }

    private var saved: PortForwardingRule? { ruleID.flatMap(app.forwardings.portForwarding) }
    private var runtime: PortForwardingRuntimeState { app.forwarding.state(for: draft.id) }
    private var normalized: PortForwardingRule? { PortForwardingEditorPolicy.normalized(draft) }
    private var canSave: Bool {
        !runtime.isActive && normalized != nil && app.hostLibrary.host(draft.hostID) != nil
            && (ruleID == nil || saved != nil)
    }
    private var isDirty: Bool { draft != original }

    var body: some View {
        VaultDetailScaffold(
            title: ruleID == nil ? AppStrings.Forwarding.newForwarding : AppStrings.Forwarding.editForwarding,
            symbol: "arrow.left.arrow.right", close: cancelEditing, closeLabel: AppStrings.Common.cancel
        ) {
            let context = app.forwarding.connection(for: draft.id)
            ZStack {
                if let context, context.journey.isPresented {
                    journey(context)
                } else {
                    Form {
                        if ruleID != nil {
                            Section {
                                LabeledContent(AppStrings.Common.status.swiftUIKey, value: runtime.label)
                                if runtime.isActive {
                                    Button(AppStrings.Common.stop.swiftUIKey) { app.forwarding.stop(draft.id) }
                                } else {
                                    Button(
                                        runtime.isFailed
                                            ? AppStrings.Common.retry.swiftUIKey
                                            : AppStrings.Forwarding.start.swiftUIKey
                                    ) { app.forwarding.start(draft.id) }
                                    .disabled(
                                        saved == nil || normalized != saved || !canSave
                                            || !PortForwardingEditorPolicy.canStart(
                                                draft.id, savedRule: saved,
                                                savedHost: app.hostLibrary.host(draft.hostID),
                                                isRuntimeActive: runtime.isActive)
                                    )
                                }
                            }
                        }
                        PortForwardingFields(rule: $draft, hosts: app.forwardings.hosts)
                            .disabled(runtime.isActive)
                        if let error { Text(error).foregroundStyle(.red) }
                        if ruleID != nil && saved == nil {
                            Text(AppStrings.Forwarding.theForwardingRuleIsUnavailable).foregroundStyle(.secondary)
                        }
                    }.formStyle(.grouped)
                        .transition(.opacity)
                }
            }
            .animation(Motion.panel(reduceMotion: reduceMotion), value: context?.journey.isPresented ?? false)
        } footer: {
            HStack(spacing: Metrics.Space.m) {
                if ruleID != nil {
                    Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) { confirmsDeletion = true }
                }
                Spacer()
                Button(AppStrings.Common.cancel.swiftUIKey, action: cancelEditing)
                Button(AppStrings.Common.save.swiftUIKey, action: saveAndClose).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(!canSave)
            }.padding(Metrics.Space.l)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let saved {
                draft = saved
                original = saved
            }
            editingToken = editingSession.register(
                route: .forwardingEditor(ruleID), isDirty: { isDirty }
            ) { commitChanges() }
        }
        .onDisappear {
            guard let editingToken else { return }
            editingSession.unregister(editingToken)
        }
        .confirmationDialog(
            AppStrings.Forwarding.deleteForwardingRuleConfirmation, isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button(AppStrings.Common.delete.swiftUIKey, role: .destructive, action: delete)
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) {}
        } message: {
            Text(AppStrings.Forwarding.anyActiveForwardingSessionForThisRuleWillBeStopped)
        }
        .alert(
            AppStrings.Common.operationFailed,
            isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })
        ) {
            Button(AppStrings.Common.ok.swiftUIKey) { deletionError = nil }
        } message: {
            Text(deletionError ?? "")
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
            securityKeySigning: context.connection.securityKeySigning,
            keyboardAuthentication: context.connection.keyboardAuthentication, cancelKeyboardAuthentication: cancel,
            isEmbedded: true)
    }
    private func cancel() {
        app.forwarding.stop(draft.id)
        window.closeVaultWork()
    }
    private func cancelEditing() {
        editingSession.requestTransition(route: .forwardingEditor(ruleID), action: window.closeVaultWork)
    }
    private func commitChanges() -> Bool {
        guard isDirty else { return true }
        guard canSave, let normalized else {
            error = String(localized: AppStrings.Common.completeAllRequiredFieldsBeforeSaving)
            return false
        }
        do {
            let saved = try app.forwardings.save(normalized)
            draft = saved
            original = saved
            error = nil
            window.selectVaultItem(.forwarding(saved.id), on: .portForwarding)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
    private func saveAndClose() {
        guard commitChanges() else { return }
        window.selectVaultItem(.forwarding(draft.id), on: .portForwarding)
        window.closeVaultWork()
    }
    private func delete() {
        guard let ruleID else { return }
        do {
            try app.forwardings.delete(ruleID)
            window.pruneVaultSelections(in: app.hostLibrary)
            window.closeVaultWork()
        } catch {
            deletionError = error.localizedDescription
        }
    }
}
