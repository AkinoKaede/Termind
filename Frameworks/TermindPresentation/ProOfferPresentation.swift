import Foundation
import TermindDomain

public nonisolated struct ProOfferPresentation: Equatable, Sendable {
    public let purchaseButtonTitle: String
    public let selectedPlanDetail: String?
    public let trialBadge: String?
    public let annualBillingUnit: String?

    public init(
        plan: ProPurchasePlan, annualPrice: String?, billingPeriod: DateComponents?,
        trialDuration: DateComponents?, canStartTrial: Bool, locale: Locale,
        localize: (String.LocalizationValue) -> String = { String(localized: $0) }
    ) {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        annualBillingUnit = Self.billingUnit(billingPeriod, formatter: formatter, localize: localize)
        let duration =
            canStartTrial
            ? trialDuration.flatMap { period -> String? in
                var components = period
                // StoreKit weeks arrive as weekOfYear, which DateComponentsFormatter does not format.
                // Preserve the offer's full duration by expressing those weeks as days.
                if let weeks = components.weekOfYear {
                    components.weekOfYear = nil
                    components.day = (components.day ?? 0) + weeks * 7
                }
                return formatter.string(from: components)
            } : nil
        trialBadge = duration.map { localize("\($0) free") }
        purchaseButtonTitle =
            switch plan {
            case .annual: localize(canStartTrial ? "Start Free Trial" : "Subscribe Annually")
            case .lifetime: localize("Buy Lifetime Access")
            }
        switch plan {
        case .annual:
            guard let price = annualPrice, let billingUnit = annualBillingUnit else {
                selectedPlanDetail = nil
                return
            }
            if let duration {
                selectedPlanDetail = localize(
                    "\(duration) free, then \(price) per \(billingUnit). Auto-renews until canceled.")
            } else {
                selectedPlanDetail = localize("\(price) per \(billingUnit). Auto-renews until canceled.")
            }
        case .lifetime:
            selectedPlanDetail = localize("One payment. No subscription or automatic renewal.")
        }
    }

    private static func billingUnit(
        _ components: DateComponents?, formatter: DateComponentsFormatter,
        localize: (String.LocalizationValue) -> String
    ) -> String? {
        guard let components else { return nil }
        if components.year == 1 { return localize("year") }
        if components.month == 1 { return localize("month") }
        if components.weekOfYear == 1 { return localize("week") }
        if components.day == 1 { return localize("day") }
        return formatter.string(from: components)
    }
}
