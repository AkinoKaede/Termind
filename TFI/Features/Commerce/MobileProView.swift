import RevenueCatUI
import SwiftUI
import TermindDomain
import TermindInfrastructure
import TermindPresentation

struct MobileProView: View {
    @Bindable var pro: ProAccessController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var ignoresPurchaseDismissal = false

    var body: some View {
        VStack(spacing: 0) {
            if pro.status == .loading {
                ProgressView(AppStrings.Pro.contactingTheAppStoreProgress.swiftUIKey)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) { closeButton }
            } else if pro.usesRevenueCat {
                PaywallView(displayCloseButton: true)
                    .customPaywallVariables(paywallVariables)
                    .onPurchaseInitiated { [pro] _, resume in
                        Task { @MainActor in resume(shouldProceed: !pro.hasProAccess) }
                    }
                    .onPurchaseCompleted { _ in
                        ignoresPurchaseDismissal = true
                        Task { await pro.completePaywallOperation() }
                    }
                    .onRestoreCompleted { _ in Task { await pro.completePaywallOperation() } }
                    .onRequestedDismissal {
                        // RevenueCat requests dismissal after purchase; keep the account variant visible.
                        if ignoresPurchaseDismissal {
                            ignoresPurchaseDismissal = false
                        } else {
                            dismiss()
                        }
                    }
            } else {
                ContentUnavailableView {
                    Label(AppStrings.Pro.termindPro, systemImage: "cart")
                } description: {
                    Text(AppStrings.Pro.productUnavailable)
                } actions: {
                    Button(AppStrings.Common.close) { dismiss() }
                }
            }
        }
        .mobileSheetPresentation()
        .onChange(of: pro.isPaywallPresented) { if !pro.isPaywallPresented { dismiss() } }
    }
    private var paywallVariables: [String: CustomVariableValue] {
        let account = ProPaywallState(status: pro.status)
        return [
            "pro": .bool(account.hasProAccess),
            "manage": .bool(account.canManageSubscription),
            "state": .string(account.state),
            "family": .bool(account.isFamilyShared),
            "dated": .bool(account.expiresAt != nil),
            "date": .string(
                account.expiresAt?.formatted(
                    .dateTime.year().month().day().hour().minute().locale(locale)) ?? ""),
        ]
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Label(AppStrings.Common.close, systemImage: "xmark")
                .labelStyle(.iconOnly)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(16)
    }

}
