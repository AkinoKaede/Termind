import AgentKit
import Foundation
import TermindApplication

/// Shared app wording for the semantic activities declared by its tool catalogs.
nonisolated enum TermindToolPresentationVocabulary {
    static let vocabulary: AgentToolPresentationVocabulary = {
        var vocabulary = AgentToolPresentationVocabulary()
        vocabulary.activity = { activityName($0, locale: $1) }
        vocabulary.countedActivity = { countedActivity($0, count: $1, locale: $2) }
        vocabulary.count = { countDescription($0, unit: $1, locale: $2) }
        return vocabulary
    }()

    private static func activityName(
        _ kind: AgentToolDescriptor.Presentation.ActivityKind, locale: Locale
    ) -> String {
        switch kind {
        case .command: localized("a command", locale: locale)
        case .commandOutput: localized(AppStrings.SSHExec.commandOutput, locale: locale)
        case .hosts: localized("hosts", locale: locale)
        case .metrics: localized("host metrics", locale: locale)
        case .plan: localized("a plan", locale: locale)
        case .question: localized("a question", locale: locale)
        case .remoteCommand: localized("the remote command", locale: locale)
        case .remoteFile: localized("a file", locale: locale)
        case .remoteDirectory: localized("a directory", locale: locale)
        case .scratchEntry: localized("a scratch entry", locale: locale)
        case .scratchFile: localized("a scratch file", locale: locale)
        case .scratchFiles: localized("scratch files", locale: locale)
        case .scratchWorkspace: localized("the scratch workspace", locale: locale)
        case .secret: localized("a secret", locale: locale)
        case .skill: localized("a skill", locale: locale)
        case .skills: localized("skills", locale: locale)
        case .memory: localized(AppStrings.Assistant.memorySearchScope, locale: locale)
        case .sessions: localized("saved conversations", locale: locale)
        case .sshCommand: localized("a command", locale: locale)
        case .suggestion: localized("a suggestion", locale: locale)
        case .taskList: localized("the task list", locale: locale)
        case .url: localized("a URL", locale: locale)
        case .web: localized("the web", locale: locale)
        default: kind.rawValue
        }
    }

    private static func countDescription(
        _ count: Int, unit: AgentToolDescriptor.Presentation.CountedUnit,
        locale: Locale
    ) -> String {
        switch unit {
        case .question: localized("\(count) questions", locale: locale)
        // Open vocabulary — an app that adds a unit and no resource for it gets
        // a plain count rather than a missing string.
        default: "\(count)"
        }
    }

    private static func countedActivity(
        _ kind: AgentToolDescriptor.Presentation.ActivityKind, count: Int, locale: Locale
    ) -> String? {
        switch kind {
        case .command, .sshCommand: return localized("\(count) commands", locale: locale)
        case .remoteFile: return localized("\(count) files", locale: locale)
        case .remoteDirectory: return localized("\(count) directories", locale: locale)
        case .scratchFile: return localized("\(count) scratch files", locale: locale)
        case .scratchEntry: return localized("\(count) scratch items", locale: locale)
        case .url: return localized("\(count) URLs", locale: locale)
        case .plan: return localized("\(count) plans", locale: locale)
        case .secret: return localized("\(count) secrets", locale: locale)
        case .suggestion: return localized("\(count) suggestions", locale: locale)
        case .taskList: return localized("the task list \(count) times", locale: locale)
        // Lists, searches, comparisons and waits can revisit the same objects.
        // Count the repetitions without inventing a number of results or files.
        default: return nil
        }
    }

    private static func localized(_ key: LocalizedStringResource, locale: Locale) -> String {
        AppLocalization.resolve(key, locale: locale)
    }
}
