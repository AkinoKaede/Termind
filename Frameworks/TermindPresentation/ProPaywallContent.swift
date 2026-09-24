import SwiftUI
import TermindApplication
import TermindDomain

public struct ProPaywallContent: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding private var selectedPlan: ProPurchasePlan
    private let background: Color
    private let cardBackground: Color
    private let presentation: ProPaywallPresentation
    private let purchase: (ProPurchasePlan) -> Void
    private let restorePurchases: () -> Void
    private let reloadProducts: () -> Void
    private let manageSubscription: () -> Void

    public init(
        presentation: ProPaywallPresentation, selectedPlan: Binding<ProPurchasePlan>,
        background: Color, cardBackground: Color,
        purchase: @escaping (ProPurchasePlan) -> Void, restorePurchases: @escaping () -> Void,
        reloadProducts: @escaping () -> Void, manageSubscription: @escaping () -> Void
    ) {
        self.background = background
        self.cardBackground = cardBackground
        self.presentation = presentation
        _selectedPlan = selectedPlan
        self.purchase = purchase
        self.restorePurchases = restorePurchases
        self.reloadProducts = reloadProducts
        self.manageSubscription = manageSubscription
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                hero
                accessStatus
                featureList
                if presentation.requestedFeature == .unlimitedMetrics {
                    Text(AppStrings.Pro.freeMetricsLimit)
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                secondaryActions
                if dynamicTypeSize.isAccessibilitySize { purchaseActions }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !dynamicTypeSize.isAccessibilitySize { purchaseActions }
        }
        .background(background)
    }

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text(AppStrings.Pro.termindPro).font(.largeTitle.bold())
            Text(AppStrings.Pro.workflowTagline)
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var accessStatus: some View {
        let status = ProAccessPresentation(status: presentation.status)
        let tint: Color =
            switch status.tone {
            case .neutral: .secondary
            case .active: .green
            case .warning: .orange
            case .revoked: .red
            }
        return HStack(spacing: 12) {
            Image(systemName: status.symbol).font(.title3.weight(.semibold)).foregroundStyle(tint)
                .frame(width: 32, height: 32).background(tint.opacity(0.14), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.title).font(.headline)
                if status.isFamilyShared, status.title.key != AppStrings.Settings.annualFamilyShared.key {
                    Text(AppStrings.Settings.annualFamilyShared).font(.caption).foregroundStyle(.secondary)
                }
                if let date = status.date, let label = status.dateLabel {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                        Text(date, format: .dateTime.year().month().day().hour().minute())
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.22), lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }

    private var featureList: some View {
        VStack(spacing: 0) {
            feature(AppStrings.Pro.assistantFeature, symbol: "sparkles")
            Divider().padding(.leading, 52)
            feature(AppStrings.Pro.metricsFeature, symbol: "waveform.path.ecg")
            Divider().padding(.leading, 52)
            feature(AppStrings.Pro.terminalUploadFeature, symbol: "arrow.up.doc")
            Divider().padding(.leading, 52)
            feature(
                presentation.supportsMCPServer
                    ? AppStrings.Pro.connectMcpToolsAndRunTheBuiltInMcpServer : AppStrings.Pro.connectRemoteMcpTools,
                symbol: "server.rack")
            Divider().padding(.leading, 52)
            feature(AppStrings.Pro.syncFeature, symbol: "icloud")
        }
        .background(cardBackground, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    @ViewBuilder private var purchaseActions: some View {
        if presentation.showsPurchaseActions {
            VStack(spacing: 8) {
                if presentation.isProcessing { ProgressView(AppStrings.Pro.contactingTheAppStoreProgress.swiftUIKey) }
                if let message = presentation.message {
                    Text(message).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if presentation.status.canPurchase {
                    let offer = ProOfferPresentation(
                        plan: selectedPlan, annualPrice: presentation.annualPrice,
                        billingPeriod: presentation.billingPeriod, trialDuration: presentation.trialDuration,
                        canStartTrial: presentation.canStartTrial, locale: locale
                    ) { AppLocalization.string($0, locale: locale) }
                    planPicker(offer)
                    Button {
                        purchase(selectedPlan)
                    } label: {
                        Text(offer.purchaseButtonTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!presentation.canPurchase(selectedPlan))
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
            .background(background, ignoresSafeAreaEdges: .bottom)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var secondaryActions: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { accountButtons }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(spacing: 10) { accountButtons }
            }
            .buttonStyle(.plain).foregroundStyle(.tint)
            if presentation.needsProductReload {
                Button(AppStrings.Pro.reloadAppStorePrices.swiftUIKey, action: reloadProducts)
                    .buttonStyle(.plain).foregroundStyle(.tint).disabled(presentation.isProcessing)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { legalLinks }.fixedSize(horizontal: true, vertical: false)
                VStack(spacing: 8) { legalLinks }
            }
            .font(.caption2)
            .buttonStyle(.plain)
            .foregroundStyle(.tint.opacity(0.7))
            Text(AppStrings.Pro.familySharingDisclosure)
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            Text(AppStrings.Settings.aiProviderUsageAndChargesAreSeparateFromTermindPro)
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
    }

    @ViewBuilder private var accountButtons: some View {
        if presentation.canManageSubscription {
            Button(AppStrings.Pro.manageSubscription.swiftUIKey, action: manageSubscription)
        }
        Button(AppStrings.Pro.restorePurchase.swiftUIKey, action: restorePurchases)
            .disabled(presentation.isProcessing)
    }

    @ViewBuilder private var legalLinks: some View {
        Link(
            AppStrings.Pro.privacyPolicy.swiftUIKey,
            destination: URL(string: "https://termind.akinokaede.com/privacy/")!)
        Link(
            AppStrings.Pro.termsOfUse.swiftUIKey,
            destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
    }

    private func planPicker(_ offer: ProOfferPresentation) -> some View {
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            planCard(
                .annual,
                title: AppStrings.Pro.annual,
                price: presentation.annualPrice,
                detail: offer.annualBillingUnit.map {
                    AppLocalization.resolve(AppStrings.Pro.billingPeriod($0), locale: locale)
                },
                badge: offer.trialBadge)
            planCard(
                .lifetime,
                title: AppStrings.Pro.lifetime,
                price: presentation.lifetimePrice,
                detail: AppLocalization.resolve(AppStrings.Pro.oneTimePurchase, locale: locale),
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
        let isAvailable = presentation.canPurchase(plan)
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
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(price ?? "—").font(.title3.bold()).foregroundStyle(.primary)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .padding(10)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06))
            .background(cardBackground)
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
