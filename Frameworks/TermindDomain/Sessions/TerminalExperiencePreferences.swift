/// Device-local feedback and power preferences, separate from synced terminal appearance.
public nonisolated struct TerminalExperiencePreferences: Equatable, Sendable {
    public var bellSound = false
    public var bellVibration = true
    public var keepScreenAwake = true

    public init() {}
}
