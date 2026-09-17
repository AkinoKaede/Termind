import StoreKit
import SwiftUI
import TermindDomain
import TermindInfrastructure
import TermindPresentation

struct MobileProView: View {
    @Bindable var pro: ProAccessController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var isManagingSubscriptions = false
    @State private var selectedPlan: ProPurchasePlan = .annual

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    hero
                    accessStatus
                    featureList
                    secondaryActions
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) { purchaseActions }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
            }
        }
        .mobileSheetPresentation()
        .task {
            await pro.reloadProducts()
            if pro.annualProduct == nil, pro.product != nil { selectedPlan = .lifetime }
        }
        .manageSubscriptionsSheet(isPresented: $isManagingSubscriptions)
    }

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text("Termind Pro").font(.largeTitle.bold())
            Text("Choose annual access or unlock Pro permanently.")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var accessStatus: some View {
        switch pro.status {
        case .loading:
            statusCard("Checking…", symbol: "arrow.triangle.2.circlepath", tint: .secondary)
        case .free:
            statusCard("Free", symbol: "person.crop.circle", tint: .secondary)
        case .subscription(let subscription):
            subscriptionStatusCard(subscription)
        case .purchased(.purchased):
            statusCard("Lifetime Access", symbol: "checkmark.seal.fill", tint: .green)
        case .purchased(.familyShared):
            statusCard("Lifetime Access · Family Shared", symbol: "person.3.fill", tint: .green)
        case .verificationFailed:
            statusCard(
                "The App Store could not verify this purchase.",
                symbol: "exclamationmark.triangle.fill", tint: .orange)
        case .unrestrictedForTesting:
            statusCard("Pro Active", symbol: "checkmark.seal.fill", tint: .green)
        }
    }

    private var featureList: some View {
        VStack(spacing: 0) {
            feature("Use the AI Assistant", symbol: "sparkles")
            Divider().padding(.leading, 52)
            feature("Monitor more than 3 servers", symbol: "waveform.path.ecg")
            Divider().padding(.leading, 52)
            feature("Upload files by dropping them on a terminal", symbol: "arrow.up.doc")
            Divider().padding(.leading, 52)
            feature("Connect remote MCP tools", symbol: "server.rack")
            Divider().padding(.leading, 52)
            feature("Sync Vault, Metrics, and Settings across devices", symbol: "icloud")
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    @ViewBuilder private var purchaseActions: some View {
        if showsPurchaseActions {
            VStack(spacing: 8) {
                if pro.isProcessing { ProgressView("Contacting the App Store…") }
                if let message = pro.message {
                    Text(message).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if pro.status.canPurchase {
                    let offer = ProOfferPresentation(
                        plan: selectedPlan, annualPrice: pro.annualDisplayPrice,
                        billingPeriod: pro.annualBillingPeriod, trialDuration: pro.annualIntroOfferDuration,
                        canStartTrial: pro.canStartTrial, locale: locale)
                    planPicker(offer)
                    Button(action: purchaseSelectedPlan) {
                        Text(offer.purchaseButtonTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!pro.canPurchase(selectedPlan))
                    if let detail = offer.selectedPlanDetail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .background(.ultraThinMaterial)
        }
    }

    private var secondaryActions: some View {
        VStack(spacing: 10) {
            if canManageSubscription {
                Button("Manage Subscription") { isManagingSubscriptions = true }
                    .buttonStyle(.plain).foregroundStyle(.tint)
            }
            Button("Restore Purchase") { Task { await pro.restorePurchases() } }
                .buttonStyle(.plain).foregroundStyle(.tint).disabled(pro.isProcessing)
            HStack(spacing: 16) {
                Link("Privacy Policy", destination: URL(string: "https://termind.akinokaede.com/privacy/")!)
                Link(
                    "Terms of Use",
                    destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            }
            .font(.caption2)
            Text("Apple Family Sharing supported · AI provider charges are separate")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
    }

    private var showsPurchaseActions: Bool {
        pro.isProcessing || pro.message != nil || pro.status.canPurchase
    }

    private func planPicker(_ offer: ProOfferPresentation) -> some View {
        HStack(spacing: 8) {
            planCard(
                .annual,
                title: "Annual",
                price: pro.annualDisplayPrice,
                detail: offer.annualBillingUnit.map { String(localized: "per \($0)") },
                badge: offer.trialBadge)
            planCard(
                .lifetime,
                title: "Lifetime",
                price: pro.displayPrice,
                detail: String(localized: "One-time purchase"),
                badge: nil)
        }
    }

    private func planCard(
        _ plan: ProPurchasePlan,
        title: LocalizedStringKey,
        price: String?,
        detail: String?,
        badge: String?
    ) -> some View {
        let isSelected = selectedPlan == plan
        let isAvailable = pro.canPurchase(plan)
        return Button {
            selectedPlan = plan
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                    }
                }
                Text(price ?? "—").font(.title3.bold()).foregroundStyle(.primary)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .padding(10)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06))
            .clipShape(.rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.2),
                        lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.55)
    }

    private func purchaseSelectedPlan() {
        switch selectedPlan {
        case .annual:
            Task { await pro.purchaseAnnual() }
        case .lifetime:
            Task { await pro.purchaseLifetime() }
        }
    }

    private var canManageSubscription: Bool {
        guard case .subscription(let subscription) = pro.status else { return false }
        return subscription.ownership == .purchased
    }

    @ViewBuilder
    private func subscriptionStatusCard(_ subscription: ProSubscriptionStatus) -> some View {
        let detail = subscription.expiresAt.map {
            Text($0, format: .dateTime.year().month().day().hour().minute())
        }
        switch subscription.phase {
        case .introductoryTrial:
            statusCard("Free Trial", symbol: "clock.fill", tint: .orange, detail: detail)
        case .subscribed:
            statusCard(
                subscription.willAutoRenew == false ? "Annual Access Until" : "Annual Subscription",
                symbol: "checkmark.seal.fill", tint: .green, detail: detail)
        case .gracePeriod:
            statusCard("Billing Grace Period", symbol: "clock.badge.exclamationmark", tint: .orange, detail: detail)
        case .billingRetry:
            statusCard(
                "Billing Issue", symbol: "creditcard.trianglebadge.exclamationmark", tint: .orange,
                detail: detail)
        case .expired:
            statusCard(
                "Subscription Expired", symbol: "calendar.badge.exclamationmark", tint: .orange,
                detail: detail)
        case .revoked:
            statusCard("Subscription Revoked", symbol: "xmark.seal", tint: .red, detail: detail)
        }
    }

    private func statusCard(
        _ title: LocalizedStringKey,
        symbol: String,
        tint: Color,
        detail: Text? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(tint)
                .frame(width: 32, height: 32).background(tint.opacity(0.14), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail { detail.font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.22), lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }

    private func feature(_ title: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.body.weight(.medium)).foregroundStyle(.tint)
                .frame(width: 32, height: 32).background(.tint.opacity(0.12), in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
