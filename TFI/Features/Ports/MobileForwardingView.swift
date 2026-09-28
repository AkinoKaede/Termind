import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import UIKit

struct MobileForwardingView: View {
    let app: MobileAppModel
    let reviewScene: MobileSceneModel?
    @State private var query: String
    @State private var editing: PortForwardingRule?
    @State private var showing: UUID?
    @State private var removing: PortForwardingRule?
    @State private var error: String?

    init(app: MobileAppModel, initialQuery: String = "", reviewScene: MobileSceneModel? = nil) {
        self.app = app
        self.reviewScene = reviewScene
        _query = State(initialValue: initialQuery)
    }

    private var rules: [PortForwardingRule] { app.forwardingLibrary.search(query) }

    var body: some View {
        MobileCardPage {
            if app.forwardingLibrary.rules.isEmpty {
                ContentUnavailableView(
                    AppStrings.Forwarding.noPortForwarding.swiftUIKey, systemImage: "arrow.left.arrow.right",
                    description: Text(AppStrings.Forwarding.createAForwardingRuleThenStartItManually))
            } else if rules.isEmpty {
                ContentUnavailableView.search(text: query)
            }
            MobileCardGrid {
                ForEach(rules) { rule in
                    card(rule)
                }
            }
        }
        .navigationTitle(AppStrings.Navigation.portForwarding.swiftUIKey)
        .searchable(text: $query.singleLineText)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(AppStrings.Forwarding.newForwarding.swiftUIKey, systemImage: "plus") {
                    editing = PortForwardingRule(hostID: UUID())
                }
            }
        }
        .navigationDestination(item: $showing) { id in
            MobileForwardingDetailView(app: app, ruleID: id)
                .mobileReviewPage("vault.portForwarding.detail", scene: reviewScene)
        }
        .sheet(item: $editing) { rule in
            MobileForwardingEditor(app: app, rule: rule, isNew: app.forwardingLibrary.portForwarding(rule.id) == nil)
        }
        .confirmationDialog(
            AppStrings.Forwarding.deleteForwardingRulesConfirmation,
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) {
                guard let removing else { return }
                do { try app.forwardingLibrary.delete(removing.id) } catch { self.error = error.localizedDescription }
                self.removing = nil
            }
        }
        .alert(
            AppStrings.Common.operationFailed,
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button(AppStrings.Common.ok.swiftUIKey) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func card(_ rule: PortForwardingRule) -> some View {
        let runtime = app.forwardings.state(for: rule.id)
        return MobileActionCard {
            showing = rule.id
        } content: {
            MobileForwardingCardContent(
                rule: rule,
                hostName: app.library.host(rule.hostID)?.name
                    ?? String(localized: AppStrings.Forwarding.hostUnavailable),
                runtime: runtime)
        } actions: {
            if runtime.isActive {
                Button(AppStrings.Common.stop.swiftUIKey, systemImage: "stop") { app.forwardings.stop(rule.id) }
            } else {
                Button(
                    runtime.isFailed ? AppStrings.Common.retry.swiftUIKey : AppStrings.Forwarding.start.swiftUIKey,
                    systemImage: "play"
                ) { start(rule) }.disabled(
                    !canStart(rule))
            }
            Button(AppStrings.Forwarding.copyAddress.swiftUIKey, systemImage: "doc.on.doc") {
                UIPasteboard.general.string = rule.bindAddress
            }
            Button(AppStrings.Vault.copySshCommand.swiftUIKey, systemImage: "apple.terminal") {
                UIPasteboard.general.string = app.forwardingLibrary.sshCommand(for: rule)
            }
            .disabled(app.forwardingLibrary.sshCommand(for: rule) == nil)
            Divider()
            Button(AppStrings.Common.edit.swiftUIKey, systemImage: "pencil") { editing = rule }.disabled(
                runtime.isActive)
            Button(AppStrings.Common.duplicate.swiftUIKey, systemImage: "plus.square.on.square") { duplicate(rule) }
            Divider()
            Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) { removing = rule }
        }
    }
    private func canStart(_ rule: PortForwardingRule) -> Bool {
        PortForwardingEditorPolicy.canStart(
            rule.id, savedRule: rule, savedHost: app.library.host(rule.hostID),
            isRuntimeActive: app.forwardings.state(for: rule.id).isActive)
    }
    private func start(_ rule: PortForwardingRule) {
        guard canStart(rule) else { return }
        showing = rule.id
        app.forwardings.start(rule.id)
    }
    private func duplicate(_ rule: PortForwardingRule) {
        var copy = rule
        copy.id = UUID()
        if !copy.label.isEmpty { copy.label += String(localized: AppStrings.Common.copySuffix) }
        do {
            editing = try app.forwardingLibrary.save(copy)
        } catch { self.error = error.localizedDescription }
    }
}

struct MobileForwardingCardContent: View {
    let rule: PortForwardingRule
    let hostName: String
    let runtime: PortForwardingRuntimeState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                MobileCardIcon(symbol: rule.kind.symbol, tint: rule.colorTag.color ?? .accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(rule.displayName(hostName: hostName)).font(.headline).lineLimit(1)
                    Text(rule.summary).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                MobileCardChip(text: rule.kind.shortDisplayName)
                Text(hostName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                MobileCardChip(text: runtime.compactLabel, symbol: runtime.isActive ? "circle.fill" : "circle")
            }
        }.accessibilityElement(children: .combine)
    }
}

struct MobileForwardingDetailView: View {
    let app: MobileAppModel
    let ruleID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var editing: PortForwardingRule?

    private var rule: PortForwardingRule? { app.forwardingLibrary.portForwarding(ruleID) }
    private var runtime: PortForwardingRuntimeState { app.forwardings.state(for: ruleID) }

    var body: some View {
        Group {
            if let rule {
                if let context = app.forwardings.connection(for: ruleID), context.journey.isPresented {
                    journey(context)
                } else {
                    Form {
                        Section {
                            LabeledContent(AppStrings.Common.status.swiftUIKey, value: runtime.label)
                        }
                        Section(AppStrings.Navigation.portForwarding.swiftUIKey) {
                            LabeledContent(
                                AppStrings.Vault.host.swiftUIKey,
                                value: app.library.host(rule.hostID)?.name
                                    ?? String(localized: AppStrings.Forwarding.hostUnavailable))
                            LabeledContent(AppStrings.Forwarding.direction.swiftUIKey, value: rule.kind.displayName)
                            Text(rule.summary).font(.body.monospaced()).textSelection(.enabled)
                            Button(AppStrings.Forwarding.copyAddress.swiftUIKey) {
                                UIPasteboard.general.string = rule.bindAddress
                            }
                            Button(AppStrings.Vault.copySshCommand.swiftUIKey) {
                                UIPasteboard.general.string = app.forwardingLibrary.sshCommand(for: rule)
                            }
                            .disabled(app.forwardingLibrary.sshCommand(for: rule) == nil)
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    AppStrings.Forwarding.theForwardingRuleIsUnavailable.swiftUIKey,
                    systemImage: "arrow.left.arrow.right")
            }
        }
        .navigationTitle(rule.map { $0.displayName(hostName: app.library.host($0.hostID)?.name) } ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if runtime.isActive {
                    Button(AppStrings.Common.stop.swiftUIKey, systemImage: "stop") { app.forwardings.stop(ruleID) }
                } else if let rule {
                    Button(
                        runtime.isFailed
                            ? AppStrings.Common.retry.swiftUIKey : AppStrings.Forwarding.start.swiftUIKey,
                        systemImage: runtime.isFailed ? "arrow.clockwise" : "play"
                    ) {
                        app.forwardings.start(ruleID)
                    }.disabled(
                        !PortForwardingEditorPolicy.canStart(
                            ruleID, savedRule: rule, savedHost: app.library.host(rule.hostID),
                            isRuntimeActive: runtime.isActive))
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                if let rule {
                    Button(AppStrings.Common.edit.swiftUIKey, systemImage: "pencil") { editing = rule }.disabled(
                        runtime.isActive)
                }
            }
        }
        .sheet(item: $editing) { rule in MobileForwardingEditor(app: app, rule: rule, isNew: false) }
    }

    private func journey(_ context: PortForwardingConnection) -> some View {
        let promptID = context.authenticationPrompt?.id
        let hostKey = context.connection.pendingHostKey
        let hostKeyRequestID = context.hostKeyRequestID
        return MobileConnectionJourneyView(
            journey: context.journey, library: app.library, authenticationPrompt: context.authenticationPrompt,
            hostKey: hostKey, reconnectState: nil,
            submit: { identity, username, password, passphrase, key, save in
                guard let promptID else { return }
                app.forwardings.submitAuthentication(
                    for: ruleID, promptID: promptID, identityID: identity,
                    username: username, password: password, passphrase: passphrase, keyID: key, save: save)
            },
            accept: { remember in
                if let hostKey, let hostKeyRequestID {
                    app.forwardings.acceptHostKey(
                        for: ruleID, requestID: hostKeyRequestID, observation: hostKey.observation, remember: remember)
                }
            },
            retry: { app.forwardings.retry(ruleID) }, retryReconnectNow: {}, stopReconnecting: {}, cancel: cancel,
            securityKeySigning: context.connection.securityKeySigning,
            keyboardAuthentication: context.connection.keyboardAuthentication, cancelKeyboardAuthentication: cancel)
    }
    private func cancel() {
        app.forwardings.stop(ruleID)
        dismiss()
    }
}
