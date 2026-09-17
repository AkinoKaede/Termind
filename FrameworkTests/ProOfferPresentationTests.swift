import Foundation
import TermindDomain
import TermindPresentation
import Testing

struct ProOfferPresentationTests {
    @Test(arguments: [ProPurchasePlan.annual, .lifetime], [false, true])
    func purchaseTitleFollowsPlanAndTrialEligibility(plan: ProPurchasePlan, eligible: Bool) {
        var fixture = OfferFixture()
        fixture.plan = plan
        fixture.canStartTrial = eligible
        let expected: String.LocalizationValue =
            switch plan {
            case .annual: eligible ? "Start Free Trial" : "Subscribe Annually"
            case .lifetime: "Buy Lifetime Access"
            }
        #expect(fixture.presentation().purchaseButtonTitle == String(localized: expected))
    }

    @Test(arguments: [false, true], [false, true])
    func annualDetailsRequireBothPriceAndBillingPeriod(hasPrice: Bool, hasPeriod: Bool) {
        var fixture = OfferFixture()
        fixture.annualPrice = hasPrice ? "$12.34" : nil
        fixture.billingPeriod = hasPeriod ? DateComponents(year: 1) : nil
        let offer = fixture.presentation()
        #expect((offer.selectedPlanDetail != nil) == (hasPrice && hasPeriod))
        if let detail = offer.selectedPlanDetail { #expect(detail.contains("$12.34")) }
    }

    @Test
    func ineligibleTrialDataDoesNotAffectTheOffer() {
        var fixture = OfferFixture()
        fixture.canStartTrial = false
        let withDuration = fixture.presentation()
        fixture.trialDuration = nil
        #expect(withDuration == fixture.presentation())
        #expect(withDuration.trialBadge == nil)
    }

    @Test
    func missingTrialDurationKeepsTheEligibleTitleWithoutInventingABadge() {
        var fixture = OfferFixture()
        let complete = fixture.presentation()
        fixture.trialDuration = nil
        let missingDuration = fixture.presentation()
        fixture.canStartTrial = false
        let paid = fixture.presentation()
        #expect(missingDuration.purchaseButtonTitle == complete.purchaseButtonTitle)
        #expect(missingDuration.purchaseButtonTitle != paid.purchaseButtonTitle)
        #expect(missingDuration.trialBadge == nil)
        #expect(missingDuration.selectedPlanDetail == paid.selectedPlanDetail)
    }

    @Test(arguments: [Calendar.Component.year, .month, .weekOfYear, .day])
    func singularPeriodsUseAUnitNameAndPreserveUnitPriority(component: Calendar.Component) {
        var fixture = OfferFixture()
        var period = DateComponents()
        period.setValue(1, for: component)
        fixture.billingPeriod = period
        let key: String.LocalizationValue =
            switch component {
            case .year: "year"
            case .month: "month"
            case .weekOfYear: "week"
            default: "day"
            }
        #expect(fixture.presentation().annualBillingUnit == String(localized: key))
        if component == .year {
            fixture.billingPeriod?.month = 1
            #expect(fixture.presentation().annualBillingUnit == String(localized: "year"))
        }
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func compositePeriodsKeepOneFullUnitInTheEffectiveLocale(identifier: String) throws {
        var fixture = OfferFixture()
        let period = DateComponents(month: 3, day: 10)
        fixture.billingPeriod = period
        let locale = Locale(identifier: identifier)
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        let expected = try #require(formatter.string(from: period))
        let offer = fixture.presentation(locale: locale)
        #expect(offer.annualBillingUnit == expected)
        #expect(offer.selectedPlanDetail?.contains(expected) == true)
        #expect(offer.selectedPlanDetail?.contains("$12.34") == true)
    }

    @Test
    func nativeDefaultLookupRemainsIndependentOfTheDurationFormattingLocale() {
        let fixture = OfferFixture()
        let english = fixture.presentation(locale: Locale(identifier: "en"))
        let chinese = fixture.presentation(locale: Locale(identifier: "zh-Hant"))
        #expect(english.purchaseButtonTitle == chinese.purchaseButtonTitle)
        #expect(english.annualBillingUnit == chinese.annualBillingUnit)
        #expect(english.trialBadge != chinese.trialBadge)
    }

    @Test
    func callerLocalizationAppliesToEveryOfferLabel() throws {
        var fixture = OfferFixture()
        let offer = fixture.presentation { "[custom]" + String(localized: $0) }
        let labels = [
            offer.purchaseButtonTitle, try #require(offer.annualBillingUnit),
            try #require(offer.trialBadge), try #require(offer.selectedPlanDetail),
        ]
        #expect(labels.allSatisfy { $0.hasPrefix("[custom]") })
        fixture.plan = .lifetime
        let lifetime = fixture.presentation { "[custom]" + String(localized: $0) }
        #expect(lifetime.purchaseButtonTitle.hasPrefix("[custom]"))
        #expect(lifetime.selectedPlanDetail?.hasPrefix("[custom]") == true)
    }

    @Test
    func lifetimeDetailsIgnoreAnnualProductAvailabilityWhileTheAnnualBadgeRemainsIndependent() {
        var fixture = OfferFixture()
        fixture.plan = .lifetime
        let complete = fixture.presentation()
        #expect(complete.trialBadge != nil)
        fixture.annualPrice = nil
        fixture.billingPeriod = nil
        fixture.trialDuration = nil
        let missing = fixture.presentation()
        #expect(missing.purchaseButtonTitle == complete.purchaseButtonTitle)
        #expect(missing.selectedPlanDetail == complete.selectedPlanDetail)
        #expect(missing.selectedPlanDetail != nil)
        #expect(missing.trialBadge == nil)
    }
}

private struct OfferFixture {
    var plan: ProPurchasePlan = .annual
    var annualPrice: String? = "$12.34"
    var billingPeriod: DateComponents? = DateComponents(year: 1)
    var trialDuration: DateComponents? = DateComponents(day: 7)
    var canStartTrial = true

    func presentation(
        locale: Locale = Locale(identifier: "en"),
        localize: (String.LocalizationValue) -> String = { String(localized: $0) }
    ) -> ProOfferPresentation {
        ProOfferPresentation(
            plan: plan, annualPrice: annualPrice, billingPeriod: billingPeriod,
            trialDuration: trialDuration, canStartTrial: canStartTrial, locale: locale, localize: localize)
    }
}
