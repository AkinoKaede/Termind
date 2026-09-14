import Foundation

public nonisolated enum CommandRisk: Int, Comparable, Sendable, CaseIterable {
    case safe = 0
    case caution = 1
    case destructive = 2

    public nonisolated static func < (lhs: CommandRisk, rhs: CommandRisk) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .safe: String(localized: "Read-only")
        case .caution: String(localized: "Caution")
        case .destructive: String(localized: "Destructive")
        }
    }

    public var symbol: String {
        switch self {
        case .safe: "eye"
        case .caution: "exclamationmark.triangle"
        case .destructive: "exclamationmark.octagon.fill"
        }
    }
}

public nonisolated struct RiskAssessment: Sendable, Hashable {
    public var risk: CommandRisk
    /// Human-readable justifications, shown under the command card so the user
    /// can see *why* something was flagged rather than trusting a bare badge.
    public var reasons: [String]

    /// Destructive commands always require a second confirmation. Caution
    /// commands require one click. Safe commands may be one-click-run if the
    /// user opted into that in Settings.
    public var requiresSecondConfirmation: Bool { risk == .destructive }

    public init(risk: CommandRisk, reasons: [String]) {
        self.risk = risk
        self.reasons = reasons
    }
}

/// Classifies a shell command by how much damage running it could do.
///
/// This runs entirely on the client and deliberately does **not** ask the model
/// to rate its own suggestion. It is advisory input to the UI and to local
/// approval/concurrency policy; it never replaces the user's authorization.
///
/// Design rule: **fail closed.** Only syntax and commands proven read-only are
/// `.safe`. Unknown commands, options, and unsupported shell forms are at least
/// `.caution`; directly destructive operations are `.destructive`.
public nonisolated enum CommandRiskClassifier {
    public static func assess(_ command: String) -> RiskAssessment {
        CommandRiskEngine.assess(command)
    }
}
