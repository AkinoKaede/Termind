import Foundation

/// One invitation budget for every app surface. StoreKit reports neither
/// presentation nor completion, so persisted records describe attempts, never ratings.
@MainActor
public final class AppReviewController {
    public static let reviewURL = URL(string: "https://apps.apple.com/app/id6805856690?action=write-review")!

    public enum Location: Equatable {
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

    public struct Context: Equatable {
        public var location: Location
        public var isActive: Bool
        public var isBlocked: Bool

        public init(location: Location, isActive: Bool, isBlocked: Bool = false) {
            self.location = location
            self.isActive = isActive
            self.isBlocked = isBlocked
        }

        var canRequest: Bool { isActive && !isBlocked && location.isReviewPage }
    }

    private struct Pending {
        let surfaceID: UUID
        let deadline: TimeInterval
    }

    private let defaults: UserDefaults?
    private let version: String
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private let calendar: Calendar
    public let isEnabled: Bool
    private var contexts: [UUID: Context] = [:]
    private var activeSurfaceID: UUID?
    private var lastTick: TimeInterval?
    private var workspaceSeconds: TimeInterval = 0
    private var pending: Pending?

    public init(
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

    public static func live() -> AppReviewController {
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
    public func update(surfaceID: UUID, context: Context) {
        guard isEnabled else { return }
        accountForWorkspaceTime()
        let previous = contexts[surfaceID]
        contexts[surfaceID] = context

        if context.isActive {
            if activeSurfaceID != surfaceID {
                pending = nil
                activeSurfaceID = surfaceID
            }
            recordActiveDay()
        } else if activeSurfaceID == surfaceID {
            activeSurfaceID = nil
        }

        if pending?.surfaceID == surfaceID,
            !context.canRequest || previous?.location != context.location
        {
            pending = nil
        }
        if previous?.isActive == true, previous?.location.isWorkspace == true,
            context.canRequest, isEligible
        {
            pending = Pending(surfaceID: surfaceID, deadline: uptime() + 3)
        }
    }

    public func recordInteraction(surfaceID: UUID) {
        accountForWorkspaceTime()
        pending = nil
        if contexts[surfaceID]?.isActive == true { activeSurfaceID = surfaceID }
    }

    public func removeSurface(_ surfaceID: UUID) {
        accountForWorkspaceTime()
        contexts.removeValue(forKey: surfaceID)
        if activeSurfaceID == surfaceID { activeSurfaceID = nil }
        recordInteraction(surfaceID: surfaceID)
    }

    public func requestIfReady(surfaceID: UUID, request: () -> Void) {
        guard let pending, pending.surfaceID == surfaceID,
            uptime() >= pending.deadline, activeSurfaceID == surfaceID,
            contexts[surfaceID]?.canRequest == true, isEligible
        else { return }
        self.pending = nil
        var versions = defaults?.stringArray(forKey: SettingsKey.reviewRequestedVersions) ?? []
        versions.append(version)
        defaults?.set(versions, forKey: SettingsKey.reviewRequestedVersions)
        defaults?.set(now(), forKey: SettingsKey.reviewLastAttempt)
        request()
    }

    public func recordManualReview() {
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
        guard let lastTick, let activeSurfaceID,
            let context = contexts[activeSurfaceID], context.isActive, context.location.isWorkspace
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
