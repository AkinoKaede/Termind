import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPresentation

struct ProPaywallView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var selectedPlan: ProPurchasePlan = .annual

    private var pro: ProAccessController { app.proAccess }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.tint)
                VStack(spacing: Metrics.Space.s) {
                    Text("Termind Pro").font(.largeTitle.bold())
                    Text("Choose annual access or unlock Pro permanently.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 24)

            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                feature("Use the AI Assistant", "sparkles")
                feature("Monitor more than 3 servers", "waveform.path.ecg")
                feature("Upload files by dropping them on a terminal", "arrow.up.doc")
                feature("Connect MCP tools and run the built-in MCP Server", "server.rack")
                feature("Sync Vault, Metrics, and Settings across devices", "icloud")
            }
            .frame(maxWidth: 460)
            .padding(.vertical, 20)

            if pro.requestedFeature == .unlimitedMetrics {
                Text("Free includes up to 3 monitoring cards. Upgrade to Pro for more.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24).padding(.bottom, 12)
            }

            if pro.isProcessing { ProgressView("Contacting the App Store…").padding(.bottom, 12) }
            if let message = pro.message {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.center).padding(.bottom, 12)
            }

            VStack(spacing: 8) {
                if pro.status.canPurchase {
                    let offer = ProOfferPresentation(
                        plan: selectedPlan, annualPrice: pro.annualDisplayPrice,
                        billingPeriod: pro.annualBillingPeriod, trialDuration: pro.annualIntroOfferDuration,
                        canStartTrial: pro.canStartTrial, locale: locale
                    ) { AppLocalization.string($0, locale: locale) }
                    planPicker(offer)
                    Button(action: purchaseSelectedPlan) {
                        Text(offer.purchaseButtonTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: 420)
                    .disabled(!canPurchaseSelectedPlan)
                    if let detail = offer.selectedPlanDetail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 420)
                    }
                }
                if canManageSubscription {
                    Link(
                        "Manage Subscription",
                        destination: URL(string: "https://apps.apple.com/account/subscriptions")!
                    )
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Button("Restore Purchase") { Task { await pro.restorePurchases() } }
                    .buttonStyle(.link)
                    .disabled(pro.isProcessing)
                if pro.annualProduct == nil || pro.product == nil {
                    Button("Reload App Store Prices") { Task { await pro.reloadProducts() } }
                        .buttonStyle(.link)
                        .disabled(pro.isProcessing)
                }
                HStack(spacing: Metrics.Space.m) {
                    Link("Privacy Policy", destination: URL(string: "https://termind.akinokaede.com/privacy/")!)
                    Link(
                        "Terms of Use",
                        destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                }
                .font(.caption2)
                Text("Apple Family Sharing supported · AI provider charges are separate")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 20)
        }
        .frame(width: 540)
        .padding(.horizontal, 32)
        .task {
            await pro.reloadProducts()
            if pro.annualProduct == nil, pro.product != nil { selectedPlan = .lifetime }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }

    private func planPicker(_ offer: ProOfferPresentation) -> some View {
        HStack(spacing: Metrics.Space.s) {
            planCard(
                .annual,
                title: "Annual",
                price: pro.annualDisplayPrice,
                detail: offer.annualBillingUnit.map { AppLocalization.string("per \($0)", locale: locale) },
                badge: offer.trialBadge)
            planCard(
                .lifetime,
                title: "Lifetime",
                price: pro.displayPrice,
                detail: AppLocalization.string("One-time purchase", locale: locale),
                badge: nil)
        }
        .frame(maxWidth: 420)
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
            VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                HStack {
                    Text(title).font(.headline)
                    Spacer(minLength: 4)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.tint.opacity(0.12), in: .capsule)
                    }
                }
                Text(price ?? "—")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .padding(12)
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

    private var canPurchaseSelectedPlan: Bool {
        pro.canPurchase(selectedPlan)
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

    private func feature(_ title: LocalizedStringKey, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.body)
    }
}

struct ProPaywallPresenter: ViewModifier {
    let app: AppModel
    let window: WindowModel

    func body(content: Content) -> some View {
        content
            .onChange(of: app.proAccess.isPaywallPresented, initial: true) {
                app.mainWindows.synchronizePaywall()
            }
            .sheet(
                isPresented: Binding(
                    get: {
                        app.proAccess.isPaywallPresented
                            && app.mainWindows.paywallOwnerID == ObjectIdentifier(window)
                    },
                    set: { presented in
                        guard app.mainWindows.paywallOwnerID == ObjectIdentifier(window) else { return }
                        app.proAccess.isPaywallPresented = presented
                        app.mainWindows.synchronizePaywall()
                    }
                )
            ) {
                ProPaywallView().environment(app)
            }
    }
}

extension View {
    func proPaywallPresenter(app: AppModel, window: WindowModel) -> some View {
        modifier(ProPaywallPresenter(app: app, window: window))
    }
}
