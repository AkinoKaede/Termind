import AgentKit
import Foundation
import TermindApplication

/// Terminal captures stay in the model payload. Transcript cards show metadata only,
/// including malformed and failed results that must never reach a raw fallback.
nonisolated enum AgentPaneToolPresentation {
    static let profiles: [String: AgentToolPresentationProfile] = [
        "builtin.\(TermindToolName.listPanes)": profile(listsPanes: true),
        "builtin.\(TermindToolName.readPane)": profile(listsPanes: false),
    ]

    private static func profile(listsPanes: Bool) -> AgentToolPresentationProfile {
        var profile = AgentToolPresentationProfile()
        profile.hidesTruncationNotice = !listsPanes
        profile.usesSummaryForSingleCompletedBatch = true
        profile.summary = { card, locale in
            if listsPanes { return AppLocalization.resolve(AppStrings.Assistant.listTerminals, locale: locale) }
            if let name = result(card)?["title"]?.stringValue, !name.isEmpty {
                return AppLocalization.resolve(AppStrings.Assistant.readTerminal(name), locale: locale)
            }
            return AppLocalization.resolve(AppStrings.Assistant.readTerminal, locale: locale)
        }
        profile.batchOperation = { cards, locale in
            let activity = AppLocalization.resolve(
                listsPanes ? AppStrings.Assistant.terminalsActivity : AppStrings.Assistant.terminalActivity,
                locale: locale)
            return .init(
                action: listsPanes ? .list : .read,
                activity: cards.count == 1
                    ? activity : AppLocalization.string("\(activity) (\(cards.count) times)", locale: locale))
        }
        profile.detail = { card, _, locale in
            guard card.result != nil else { return .hidden }
            let object = result(card) ?? [:]
            if listsPanes {
                let rows = (object["panes"]?.arrayValue ?? []).compactMap { value -> AgentToolDetail.ListRow? in
                    guard let pane = value.objectValue,
                        let title = pane["title"]?.stringValue, let id = pane["pane_id"]?.stringValue
                    else { return nil }
                    var badges: [String] = []
                    if pane["is_active"]?.boolValue == true {
                        badges.append(AppLocalization.resolve(AppStrings.Assistant.activeTerminal, locale: locale))
                    }
                    if pane["is_current"]?.boolValue == true {
                        badges.append(AppLocalization.resolve(AppStrings.Assistant.currentTerminal, locale: locale))
                    }
                    return .init(title: title, subtitle: id, badges: badges, symbol: "terminal")
                }
                return .content(
                    .init(items: [
                        .list(
                            .init(
                                rows: rows,
                                emptyMessage: AppLocalization.resolve(
                                    AppStrings.Assistant.noOpenTerminals, locale: locale)))
                    ]))
            }
            var items: [AgentToolDetail.Item] = []
            if let name = object["title"]?.stringValue {
                items.append(
                    .field(
                        .init(
                            label: AppLocalization.resolve(AppStrings.Assistant.terminalName, locale: locale),
                            value: name)))
            }
            if let id = object["pane_id"]?.stringValue
                ?? card.invocation.call.arguments.objectValue?["pane_id"]?.stringValue
            {
                items.append(
                    .field(
                        .init(
                            label: AppLocalization.resolve(AppStrings.Assistant.paneID, locale: locale), value: id,
                            isMonospaced: true)))
            }
            return .content(.init(items: items))
        }
        return profile
    }

    private static func result(_ card: AgentToolCard) -> [String: AgentJSONValue]? {
        guard let result = card.result else { return nil }
        return (try? AgentJSONValue.decode(Data((result.untrustedPayload ?? result.content).utf8)))?.objectValue
    }
}
