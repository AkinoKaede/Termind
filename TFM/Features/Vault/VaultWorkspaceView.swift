// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindPresentation

/// Coordinates draft commits when pointer navigation leaves one of Vault's
/// inline editors. The registration is view-owned and tokened so a disappearing
/// editor cannot unregister the editor that replaced it in the same update.
@Observable
final class VaultWorkEditingSession {
    enum Confirmation {
        case saveChanges
        case discardChanges
    }

    private struct Registration {
        let token: UUID
        let route: VaultWorkRoute
        let isDirty: () -> Bool
        let isBusy: () -> Bool
        let commit: () async -> Bool
    }

    private struct PendingTransition {
        let id = UUID()
        let confirmation: Confirmation
        let action: () -> Void
    }

    @ObservationIgnored private var registration: Registration?
    @ObservationIgnored private var pendingTransition: PendingTransition?
    @ObservationIgnored private var isCommitting = false
    var confirmationID: UUID?
    private(set) var confirmation: Confirmation = .saveChanges
    private(set) var discardQuestion = AppStrings.Common.discardChangesQuestion

    @discardableResult
    func register(
        route: VaultWorkRoute, isDirty: @escaping () -> Bool,
        isBusy: @escaping () -> Bool = { false },
        commit: @escaping () async -> Bool
    ) -> UUID {
        let token = UUID()
        registration = Registration(token: token, route: route, isDirty: isDirty, isBusy: isBusy, commit: commit)
        return token
    }

    func unregister(_ token: UUID) {
        guard registration?.token == token else { return }
        registration = nil
    }

    func requestCancellation(route: VaultWorkRoute, action: @escaping () -> Void) {
        requestTransition(route: route, confirmation: .discardChanges, action: action)
    }

    func requestTransition(
        route: VaultWorkRoute, confirmation: Confirmation = .saveChanges, action: @escaping () -> Void
    ) {
        guard !isCommitting else { return }
        if let registration, registration.route == route, registration.isBusy() { return }
        guard let registration, registration.route == route, registration.isDirty() else {
            action()
            return
        }
        let pending = PendingTransition(confirmation: confirmation, action: action)
        pendingTransition = pending
        self.confirmation = confirmation
        discardQuestion = route.discardQuestion
        confirmationID = pending.id
    }

    func saveAndProceed() {
        guard let registration, let pendingTransition else { return }
        guard pendingTransition.confirmation == .saveChanges else { return }
        guard !isCommitting, !registration.isBusy() else { return }
        isCommitting = true
        Task {
            let saved = await registration.commit()
            isCommitting = false
            guard saved else {
                cancelTransition()
                return
            }
            self.pendingTransition = nil
            confirmationID = nil
            pendingTransition.action()
        }
    }

    func discardAndProceed() {
        guard !isCommitting, registration?.isBusy() != true else { return }
        guard let pendingTransition else { return }
        self.pendingTransition = nil
        confirmationID = nil
        pendingTransition.action()
    }

    func cancelTransition() {
        pendingTransition = nil
        confirmationID = nil
    }
}

struct VaultWorkspaceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VaultWorkspaceContent(reduceMotion: reduceMotion)
    }
}

struct VaultWorkspaceContent: View {
    @Environment(WindowModel.self) private var window
    @State private var editingSession = VaultWorkEditingSession()
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geometry in
            let showsDetail = window.vaultWorkRoute != nil
            let showsList = !showsDetail || geometry.size.width >= Metrics.VaultContent.splitMinWidth

            VaultWorkspaceLayout(showsDetail: showsDetail) {
                VaultView(pages: window.vaultPages)
                    .opacity(showsList ? 1 : 0)
                    .allowsHitTesting(showsList)
                    .disabled(!showsList)
                    .accessibilityHidden(!showsList)

                Divider()
                    .opacity(showsDetail && showsList ? 1 : 0)

                ZStack {
                    if let route = window.vaultWorkRoute {
                        VaultWorkDetailView(route: route)
                            .id(route)
                            .transition(.opacity)
                    }
                }
                .clipped()
                .opacity(showsDetail ? 1 : 0)
                .allowsHitTesting(showsDetail)
                .disabled(!showsDetail)
                .accessibilityHidden(!showsDetail)
            }
            .clipped()
            .animation(Motion.panel(reduceMotion: reduceMotion), value: window.vaultWorkRoute)
        }
        .environment(editingSession)
        .confirmationDialog(
            editingSession.confirmation == .saveChanges
                ? AppStrings.Vault.saveChangesConfirmation : AppStrings.Common.discardChangesConfirmation,
            isPresented: Binding(
                get: { editingSession.confirmationID != nil },
                set: { if !$0 { editingSession.cancelTransition() } }
            ),
            titleVisibility: .visible
        ) {
            if editingSession.confirmation == .saveChanges {
                Button(AppStrings.Common.save.swiftUIKey, action: editingSession.saveAndProceed)
                Button(
                    AppStrings.Common.discard.swiftUIKey, role: .destructive, action: editingSession.discardAndProceed)
                Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel, action: editingSession.cancelTransition)
            } else {
                Button(AppStrings.Common.keepEditing.swiftUIKey, role: .cancel, action: editingSession.cancelTransition)
                    .keyboardShortcut(.defaultAction)
                Button(
                    AppStrings.Common.discardChanges.swiftUIKey, role: .destructive,
                    action: editingSession.discardAndProceed)
            }
        } message: {
            Text(
                editingSession.confirmation == .saveChanges
                    ? AppStrings.Vault.saveChangesMessage : editingSession.discardQuestion)
        }
    }
}

extension VaultWorkRoute {
    var discardQuestion: LocalizedStringResource {
        switch self {
        case .hostEditor(nil, _, _): AppStrings.Common.discardNewHostQuestion
        case .hostGroupEditor(nil, _): AppStrings.Common.discardNewGroupQuestion
        case .forwardingEditor(nil): AppStrings.Common.discardNewForwardingQuestion
        case .identityEditor(nil): AppStrings.Common.discardNewIdentityQuestion
        case .generateKey, .importKey: AppStrings.Common.discardNewKeyQuestion
        case .knownHostEditor(nil): AppStrings.Common.discardNewKnownHostQuestion
        case .snippetEditor(nil, _): AppStrings.Common.discardNewSnippetQuestion
        case .snippetPackageEditor(nil, _): AppStrings.Common.discardNewPackageQuestion
        default: AppStrings.Common.discardChangesQuestion
        }
    }
}

/// The children never change identity at the breakpoint. A covered list keeps
/// its last visible size so returning from an editor also keeps its scroll position.
struct VaultWorkspaceLayout: Layout {
    var showsDetail: Bool
    private var expansion: CGFloat

    init(showsDetail: Bool) {
        self.showsDetail = showsDetail
        expansion = showsDetail ? 1 : 0
    }

    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    struct Cache {
        var listSize: CGSize?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 3 else { return }
        let split = bounds.width >= Metrics.VaultContent.splitMinWidth
        let progress = min(1, max(0, expansion))
        // Keep the editor at its open width even while it leaves. Only its
        // position and the list's reserved space animate, never the form's width.
        let detailWidth = split ? Metrics.VaultDetail.width : bounds.width
        let listWidth = split ? bounds.width - (detailWidth + 1) * progress : bounds.width
        let listIsVisible = !showsDetail || split
        let listSize = listIsVisible ? CGSize(width: listWidth, height: bounds.height) : cache.listSize ?? bounds.size
        if listIsVisible { cache.listSize = listSize }

        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(listSize))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + listWidth, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: split ? 1 : 0, height: bounds.height)
        )
        subviews[2].place(
            at: CGPoint(x: bounds.maxX - detailWidth * progress, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: detailWidth, height: bounds.height)
        )
    }
}
