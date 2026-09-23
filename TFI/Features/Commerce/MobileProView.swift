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
                    Button(AppStrings.Common.close.swiftUIKey, systemImage: "xmark") { dismiss() }.labelStyle(
                        .iconOnly)
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
            Text(AppStrings.Pro.termindPro).font(.largeTitle.bold())
            Text(AppStrings.Pro.planExplanation)
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var accessStatus: some View {
        switch pro.status {
        case .loading:
            statusCard(AppStrings.Pro.checkingProgress, symbol: "arrow.triangle.2.circlepath", tint: .secondary)
        case .free:
            statusCard(AppStrings.Pro.free, symbol: "person.crop.circle", tint: .secondary)
        case .subscription(let subscription):
            subscriptionStatusCard(subscription)
        case .purchased(.purchased):
            statusCard(AppStrings.Pro.lifetimeAccess, symbol: "checkmark.seal.fill", tint: .green)
        case .purchased(.familyShared):
            statusCard(AppStrings.Pro.lifetimeAccessFamilyShared, symbol: "person.3.fill", tint: .green)
        case .verificationFailed:
            statusCard(
                AppStrings.Pro.theAppStoreCouldNotVerifyThisPurchase,
                symbol: "exclamationmark.triangle.fill", tint: .orange)
        case .unrestrictedForTesting:
            statusCard(AppStrings.Pro.proActive, symbol: "checkmark.seal.fill", tint: .green)
        }
    }

    private var featureList: some View {
        VStack(spacing: 0) {
            feature(AppStrings.Pro.assistantFeature, symbol: "sparkles")
            Divider().padding(.leading, 52)
            feature(AppStrings.Pro.metricsFeature, symbol: "waveform.path.ecg")
            Divider().padding(.leading, 52)
            feature(AppStrings.Pro.terminalUploadFeature, symbol: "arrow.up.doc")
            Divider().padding(.leading, 52)
            feature(AppStrings.Pro.connectRemoteMcpTools, symbol: "server.rack")
            Divider().padding(.leading, 52)
            feature(AppStrings.Pro.syncFeature, symbol: "icloud")
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    @ViewBuilder private var purchaseActions: some View {
        if showsPurchaseActions {
            VStack(spacing: 8) {
                if pro.isProcessing { ProgressView(AppStrings.Pro.contactingTheAppStoreProgress.swiftUIKey) }
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
                Button(AppStrings.Pro.manageSubscription.swiftUIKey) { isManagingSubscriptions = true }
                    .buttonStyle(.plain).foregroundStyle(.tint)
            }
            Button(AppStrings.Pro.restorePurchase.swiftUIKey) { Task { await pro.restorePurchases() } }
                .buttonStyle(.plain).foregroundStyle(.tint).disabled(pro.isProcessing)
            HStack(spacing: 16) {
                Link(
                    AppStrings.Pro.privacyPolicy.swiftUIKey,
                    destination: URL(string: "https://termind.akinokaede.com/privacy/")!)
                Link(
                    AppStrings.Pro.termsOfUse.swiftUIKey,
                    destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            }
            .font(.caption2)
            Text(AppStrings.Pro.familySharingDisclosure)
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
                title: AppStrings.Pro.annual,
                price: pro.annualDisplayPrice,
                detail: offer.annualBillingUnit.map { String(localized: AppStrings.Pro.billingPeriod($0)) },
                badge: offer.trialBadge)
            planCard(
                .lifetime,
                title: AppStrings.Pro.lifetime,
                price: pro.displayPrice,
                detail: String(localized: AppStrings.Pro.oneTimePurchase),
                badge: nil)
        }
    }

    private func planCard(
        _ plan: ProPurchasePlan,
        title: LocalizedStringResource,
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
            statusCard(AppStrings.Pro.freeTrial, symbol: "clock.fill", tint: .orange, detail: detail)
        case .subscribed:
            statusCard(
                subscription.willAutoRenew == false
                    ? AppStrings.Pro.annualAccessUntil : AppStrings.Pro.annualSubscription,
                symbol: "checkmark.seal.fill", tint: .green, detail: detail)
        case .gracePeriod:
            statusCard(
                AppStrings.Pro.billingGracePeriod, symbol: "clock.badge.exclamationmark", tint: .orange, detail: detail
            )
        case .billingRetry:
            statusCard(
                AppStrings.Pro.billingIssue, symbol: "creditcard.trianglebadge.exclamationmark", tint: .orange,
                detail: detail)
        case .expired:
            statusCard(
                AppStrings.Pro.subscriptionExpired, symbol: "calendar.badge.exclamationmark", tint: .orange,
                detail: detail)
        case .revoked:
            statusCard(AppStrings.Pro.subscriptionRevoked, symbol: "xmark.seal", tint: .red, detail: detail)
        }
    }

    private func statusCard(
        _ title: LocalizedStringResource,
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

    private func feature(_ title: LocalizedStringResource, symbol: String) -> some View {
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
