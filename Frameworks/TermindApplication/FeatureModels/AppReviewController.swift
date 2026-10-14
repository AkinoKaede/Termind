import Foundation
import Observation

/// Device-local invitation state, shared by all windows. Opening the store
/// records an intent to review, never a completed rating.
@MainActor @Observable
public final class AppReviewController {
    public static let reviewURL = URL(string: "https://apps.apple.com/app/id6805856690?action=write-review")!

    public enum Response: String {
        case declined
        case openedReview
    }

    public private(set) var response: Response?
    public private(set) var isPreviewEnabled = false
    public private(set) var previewResponse: Response?
    public let isEnabled: Bool
    private let defaults: UserDefaults?
    private let now: () -> Date
    private let firstUse: Date

    public init(
        defaults: UserDefaults? = nil, isEnabled: Bool = false,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.isEnabled = isEnabled
        self.now = now
        firstUse = defaults?.object(forKey: SettingsKey.reviewFirstUse) as? Date ?? now()
        response = defaults?.string(forKey: SettingsKey.reviewInvitationResponse).flatMap(Response.init(rawValue:))
        if isEnabled, defaults?.object(forKey: SettingsKey.reviewFirstUse) == nil {
            defaults?.set(firstUse, forKey: SettingsKey.reviewFirstUse)
        }
    }

    public static func live() -> AppReviewController {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return AppReviewController(defaults: isTesting ? nil : .standard, isEnabled: !isTesting)
    }

    public func isEligible(hasHosts: Bool) -> Bool {
        isEnabled && response == nil && hasHosts && now().timeIntervalSince(firstUse) >= 7 * 86_400
    }

    public func setPreviewEnabled(_ enabled: Bool) {
        isPreviewEnabled = enabled
        previewResponse = nil
    }

    public func decline() {
        setResponse(.declined)
    }

    public func openReview(using open: (URL, @escaping (Bool) -> Void) -> Void) {
        if isPreviewEnabled {
            previewResponse = .openedReview
            return
        }
        open(Self.reviewURL) { [weak self] accepted in
            guard let self, accepted, self.isEnabled else { return }
            self.response = .openedReview
            self.defaults?.set(Response.openedReview.rawValue, forKey: SettingsKey.reviewInvitationResponse)
        }
    }

    private func setResponse(_ response: Response) {
        if isPreviewEnabled {
            previewResponse = response
            return
        }
        guard isEnabled else { return }
        self.response = response
        defaults?.set(response.rawValue, forKey: SettingsKey.reviewInvitationResponse)
    }
}

/// Eligibility is captured on entry, so age or a synced host cannot insert
/// an invitation into a page the user is already interacting with.
@MainActor
public struct AppReviewInvitationVisit {
    private var eligibleOnEntry = false

    public init() {}

    public mutating func enter(controller: AppReviewController, hasHosts: Bool) {
        eligibleOnEntry = controller.isEligible(hasHosts: hasHosts)
    }

    public func isVisible(controller: AppReviewController, hasHosts: Bool, isFiltering: Bool) -> Bool {
        if controller.isPreviewEnabled {
            return controller.previewResponse == nil && !isFiltering
        }
        return eligibleOnEntry && controller.isEnabled && controller.response == nil && hasHosts && !isFiltering
    }
}
