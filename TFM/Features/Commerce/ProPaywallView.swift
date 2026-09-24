import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPresentation

struct ProPaywallView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var selectedPlan: ProPurchasePlan = .annual

    private var pro: ProAccessController { app.proAccess }

    var body: some View {
        ProPaywallContent(
            presentation: presentation, selectedPlan: $selectedPlan,
            background: TermindColor.windowSurface, cardBackground: TermindColor.contentSurface, purchase: purchase,
            restorePurchases: { Task { await pro.restorePurchases() } },
            reloadProducts: { Task { await pro.reloadProducts() } },
            manageSubscription: { openURL(URL(string: "https://apps.apple.com/account/subscriptions")!) }
        )
        .frame(width: 604, height: 640)
        .overlay(alignment: .topLeading) {
            closeButton.padding(16)
        }
        .task {
            await pro.reloadProducts()
            if pro.annualProduct == nil, pro.product != nil { selectedPlan = .lifetime }
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Label(AppStrings.Common.close, systemImage: "xmark")
                .labelStyle(.iconOnly)
                .frame(width: 30, height: 30)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .termindGlassCircle(isInteractive: true)
        .termindInputAwareFocusEffect()
        .keyboardShortcut(.cancelAction)
        .help(AppStrings.Common.close)
        .accessibilityLabel(Text(AppStrings.Common.close))
    }

    private var presentation: ProPaywallPresentation {
        ProPaywallPresentation(
            status: pro.status, annualPrice: pro.annualDisplayPrice, lifetimePrice: pro.displayPrice,
            billingPeriod: pro.annualBillingPeriod, trialDuration: pro.annualIntroOfferDuration,
            canStartTrial: pro.canStartTrial, canPurchaseAnnual: pro.canPurchase(.annual),
            canPurchaseLifetime: pro.canPurchase(.lifetime), isProcessing: pro.isProcessing,
            message: pro.message, requestedFeature: pro.requestedFeature, supportsMCPServer: true)
    }

    private func purchase(_ plan: ProPurchasePlan) {
        Task {
            switch plan {
            case .annual: await pro.purchaseAnnual()
            case .lifetime: await pro.purchaseLifetime()
            }
        }
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
                    .allowsApplicationTerminationWhenModal()
            }
    }
}

extension View {
    func proPaywallPresenter(app: AppModel, window: WindowModel) -> some View {
        modifier(ProPaywallPresenter(app: app, window: window))
    }
}
