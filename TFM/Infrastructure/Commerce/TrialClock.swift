import Foundation
import TermindDomain

/// This watermark can only shorten a verified trial, never grant one. It is a
/// best-effort clock rollback guard, not a second store of purchase eligibility.
struct TrialClock {
    let defaults: UserDefaults?

    func effectiveNow(for trial: ProTrial, now: Date) -> Date {
        let key = "commerce.pro.trial-clock.\(trial.originalID)"
        let lastObserved = defaults?.object(forKey: key) as? Date ?? trial.purchasedAt
        let effective = max(now, lastObserved, trial.purchasedAt)
        defaults?.set(effective, forKey: key)
        return effective
    }
}
