import StoreKit
import SwiftUI
import TermindDomain
import TermindInfrastructure
import TermindPresentation

struct MobileProView: View {
    @Bindable var pro: ProAccessController
    @Environment(\.dismiss) private var dismiss
    @State private var isManagingSubscriptions = false
    @State private var selectedPlan: ProPurchasePlan = .annual

    var body: some View {
        NavigationStack {
            ProPaywallContent(
                presentation: presentation, selectedPlan: $selectedPlan,
                background: Color(uiColor: .systemGroupedBackground),
                cardBackground: Color(uiColor: .secondarySystemGroupedBackground), purchase: purchase,
                restorePurchases: { Task { await pro.restorePurchases() } },
                reloadProducts: { Task { await pro.reloadProducts() } },
                manageSubscription: { isManagingSubscriptions = true }
            )
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppStrings.Common.close.swiftUIKey, systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
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

    private var presentation: ProPaywallPresentation {
        ProPaywallPresentation(
            status: pro.status, annualPrice: pro.annualDisplayPrice, lifetimePrice: pro.displayPrice,
            billingPeriod: pro.annualBillingPeriod, trialDuration: pro.annualIntroOfferDuration,
            canStartTrial: pro.canStartTrial, canPurchaseAnnual: pro.canPurchase(.annual),
            canPurchaseLifetime: pro.canPurchase(.lifetime), isProcessing: pro.isProcessing,
            message: pro.message, requestedFeature: pro.requestedFeature, supportsMCPServer: false)
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
