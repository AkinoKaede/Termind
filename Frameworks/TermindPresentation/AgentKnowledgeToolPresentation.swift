import AgentKit
import Foundation
import TermindApplication

/// Render-time repair also covers cards persisted with the original, incorrect skill fallback.
/// A remote tool or an unknown explicit presenter ID can never opt into this policy by name alone.
nonisolated enum AgentKnowledgeToolPresentation {
    enum Kind: String {
        case skillsList = "skills_list"
        case skillRead = "skill_read_file"
        case skillManage = "skill_manage"
        case skillInstall = "skill_install"
        case memory
        case memorySearch = "memory_search"
        case sessionSearch = "session_search"
        case legacySkill = "load_skill"
    }

    struct Operation {
        let action: AgentToolDescriptor.Presentation.ActionKind
        let activity: String
        let batchActivity: String
        var isArgument = false
    }

    static func kind(for descriptor: AgentToolDescriptor) -> Kind? {
        guard descriptor.target == .local, let kind = Kind(rawValue: descriptor.name) else { return nil }
        if let id = descriptor.presentation?.presenterID, id != "builtin.\(kind.rawValue)" { return nil }
        return kind
    }

    static func scopedSearchSummary(for card: AgentToolCard, locale: Locale) -> String? {
        guard card.state == .running || card.state == .completed else { return nil }
        guard let search = scopedSearch(for: card, locale: locale) else { return nil }
        func rendered(_ query: String) -> String {
            switch card.state {
            case .running:
                AppLocalization.resolve(AppStrings.Assistant.searching(query, in: search.scope), locale: locale)
            default:
                AppLocalization.resolve(AppStrings.Assistant.searched(query, in: search.scope), locale: locale)
            }
        }
        let query = search.query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let available = max(0, 80 - rendered("").count)
        let displayed = query.count > available ? String(query.prefix(max(0, available - 1))) + "…" : query
        return title(rendered(displayed))
    }

    private static func scopedSearch(for card: AgentToolCard, locale: Locale) -> (query: String, scope: String)? {
        guard let kind = kind(for: card.descriptor), kind == .memorySearch || kind == .sessionSearch,
            let query = AgentToolDetailFormatting.nonempty(
                card.invocation.call.arguments.objectValue?["query"]?.stringValue)
        else { return nil }
        let scope: String
        switch kind {
        case .memorySearch:
            let resource =
                card.invocation.call.arguments.objectValue?["target"]?.stringValue == "user"
                ? AppStrings.Assistant.userProfileSearchScope : AppStrings.Assistant.memorySearchScope
            scope = AppLocalization.resolve(resource, locale: locale)
        case .sessionSearch:
            scope = AppLocalization.resolve(AppStrings.Assistant.chatsSearchScope, locale: locale)
        default: return nil
        }
        return (query, scope)
    }

    static func operation(for card: AgentToolCard, locale: Locale, approval: Bool = false) -> Operation? {
        guard let kind = kind(for: card.descriptor) else { return nil }
        let args = card.invocation.call.arguments.objectValue ?? [:]
        func localized(_ key: String.LocalizationValue) -> String { AppLocalization.string(key, locale: locale) }
        func string(_ key: String) -> String? {
            AgentToolDetailFormatting.nonempty(args[key]?.stringValue)
        }
        let skills = localized("skills")
        let memory = localized("persistent memory")
        let sessions = localized("saved conversations")
        switch kind {
        case .skillsList:
            return .init(action: .list, activity: skills, batchActivity: skills)
        case .skillRead, .legacySkill:
            let listing = string("path") == "."
            let fallback = listing ? localized("skill files") : localized("a skill")
            guard !approval, let name = string("name") else {
                return .init(action: listing ? .list : .read, activity: fallback, batchActivity: skills)
            }
            let path = string("path") ?? "SKILL.md"
            return .init(
                action: listing ? .list : .read, activity: listing ? name : "\(name) / \(path)", batchActivity: skills,
                isArgument: true)
        case .skillManage:
            let operations = args["operations"]?.arrayValue ?? []
            let names = Set(
                operations.compactMap { AgentToolDetailFormatting.nonempty($0.objectValue?["name"]?.stringValue) })
            let name = !approval && names.count == 1 ? names.first : nil
            let activity = name ?? skills
            let counted = operations.count > 1 ? localized("\(activity) (\(operations.count) operations)") : activity
            return .init(action: .update, activity: counted, batchActivity: skills, isArgument: name != nil)
        case .skillInstall:
            let name = approval ? nil : string("name")
            return .init(
                action: .install, activity: name ?? localized("a skill"), batchActivity: skills,
                isArgument: name != nil
            )
        case .memory:
            let operations = args["operations"]?.arrayValue
            let reading = operations?.isEmpty == true
            let count = operations?.count ?? 0
            let activity = count > 1 ? localized("\(memory) (\(count) operations)") : memory
            return .init(action: reading ? .read : .update, activity: activity, batchActivity: memory)
        case .memorySearch:
            if let query = string("query") {
                return .init(
                    action: .search, activity: approval ? memory : query, batchActivity: memory,
                    isArgument: !approval)
            }
            return .init(action: .search, activity: memory, batchActivity: memory)
        case .sessionSearch:
            if let query = string("query") {
                return .init(
                    action: .search, activity: approval ? sessions : query, batchActivity: sessions,
                    isArgument: !approval)
            }
            return .init(
                action: string("conversation_id") == nil ? .list : .read, activity: sessions, batchActivity: sessions)
        }
    }

    static func title(_ text: String) -> String {
        let oneLine = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return oneLine.count > 80 ? String(oneLine.prefix(79)) + "…" : oneLine
    }
}
