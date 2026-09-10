import Foundation

/// One invitation budget for every window. StoreKit reports neither presentation
/// nor completion, so persisted records describe attempts, never ratings.
@MainActor
final class AppReviewController {
    static let reviewURL = URL(string: "https://apps.apple.com/app/id6805856690?action=write-review")!

    enum Location: Equatable {
        case workspace(UUID)
        case reviewPage(String)
        case other

        var isWorkspace: Bool {
            if case .workspace = self { return true }
            return false
        }

        var isReviewPage: Bool {
            if case .reviewPage = self { return true }
            return false
        }
    }

    struct Context: Equatable {
        var location: Location
        var isActive: Bool
        var isBlocked: Bool = false

        var canRequest: Bool { isActive && !isBlocked && location.isReviewPage }
    }

    private struct Pending {
        let windowID: UUID
        let deadline: TimeInterval
    }

    private let defaults: UserDefaults?
    private let version: String
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private let calendar: Calendar
    let isEnabled: Bool
    private var contexts: [UUID: Context] = [:]
    private var activeWindowID: UUID?
    private var lastTick: TimeInterval?
    private var workspaceSeconds: TimeInterval = 0
    private var pending: Pending?

    init(
        defaults: UserDefaults? = nil, version: String = "",
        isEnabled: Bool = false, now: @escaping () -> Date = Date.init,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.defaults = defaults
        self.version = version
        self.isEnabled = isEnabled
        self.now = now
        self.uptime = uptime
        self.calendar = calendar
    }

    static func live() -> AppReviewController {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return AppReviewController(
            defaults: isTesting ? nil : .standard,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            isEnabled: !isTesting
        )
    }

    /// Called on navigation, native activity changes and foreground timer ticks.
    /// Only a workspace-to-list transition can arm a request; becoming eligible,
    /// dismissing a sheet, or regaining focus alone never does.
    func update(windowID: UUID, context: Context) {
        guard isEnabled else { return }
        accountForWorkspaceTime()
        let previous = contexts[windowID]
        contexts[windowID] = context

        if context.isActive {
            if activeWindowID != windowID {
                pending = nil
                activeWindowID = windowID
            }
            recordActiveDay()
        } else if activeWindowID == windowID {
            activeWindowID = nil
        }

        if pending?.windowID == windowID,
            !context.canRequest || previous?.location != context.location
        {
            pending = nil
        }
        if previous?.isActive == true, previous?.location.isWorkspace == true,
            context.canRequest, isEligible
        {
            pending = Pending(windowID: windowID, deadline: uptime() + 3)
        }
    }

    func recordInteraction(windowID: UUID) {
        if pending?.windowID == windowID { pending = nil }
    }

    func removeWindow(_ windowID: UUID) {
        accountForWorkspaceTime()
        contexts.removeValue(forKey: windowID)
        if activeWindowID == windowID { activeWindowID = nil }
        recordInteraction(windowID: windowID)
    }

    func requestIfReady(windowID: UUID, request: () -> Void) {
        guard let pending, pending.windowID == windowID,
            uptime() >= pending.deadline, activeWindowID == windowID,
            contexts[windowID]?.canRequest == true, isEligible
        else { return }
        self.pending = nil
        var versions = defaults?.stringArray(forKey: SettingsKey.reviewRequestedVersions) ?? []
        versions.append(version)
        defaults?.set(versions, forKey: SettingsKey.reviewRequestedVersions)
        defaults?.set(now(), forKey: SettingsKey.reviewLastAttempt)
        request()
    }

    func recordManualReview() {
        pending = nil
        defaults?.set(now(), forKey: SettingsKey.reviewLastAttempt)
    }

    private var isEligible: Bool {
        guard isEnabled, !version.isEmpty, workspaceSeconds >= 300,
            let firstUse = defaults?.object(forKey: SettingsKey.reviewFirstUse) as? Date,
            now().timeIntervalSince(firstUse) >= 7 * 86_400,
            (defaults?.stringArray(forKey: SettingsKey.reviewActiveDays)?.count ?? 0) >= 3,
            !(defaults?.stringArray(forKey: SettingsKey.reviewRequestedVersions) ?? []).contains(version)
        else { return false }
        if let lastAttempt = defaults?.object(forKey: SettingsKey.reviewLastAttempt) as? Date {
            return now().timeIntervalSince(lastAttempt) >= 120 * 86_400
        }
        return true
    }

    private func accountForWorkspaceTime() {
        let tick = uptime()
        defer { lastTick = tick }
        guard let lastTick, let activeWindowID,
            let context = contexts[activeWindowID], context.isActive, context.location.isWorkspace
        else { return }
        workspaceSeconds += max(0, tick - lastTick)
    }

    private func recordActiveDay() {
        let date = now()
        if defaults?.object(forKey: SettingsKey.reviewFirstUse) == nil {
            defaults?.set(date, forKey: SettingsKey.reviewFirstUse)
        }
        var days = defaults?.stringArray(forKey: SettingsKey.reviewActiveDays) ?? []
        // Three distinct local dates prove eligibility; no growing usage log.
        guard days.count < 3 else { return }
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        let key = "\(parts.era ?? 0)-\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
        guard !days.contains(key) else { return }
        days.append(key)
        defaults?.set(days, forKey: SettingsKey.reviewActiveDays)
    }
}
