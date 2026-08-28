import Foundation

/// UI-neutral content chosen by a tool and rendered by the transcript.
/// It deliberately contains no SwiftUI types or executable persisted state.
nonisolated struct AgentToolDetail: Equatable, Sendable {
    var items: [Item]

    nonisolated enum Item: Equatable, Sendable {
        case field(Field)
        case message(String, Tint)
        case text(TextBlock)
        case list(ListBlock)
        case groupedList(GroupedList)
    }

    nonisolated struct Field: Equatable, Sendable {
        var label: String
        var value: String
        var isMonospaced = false
        var url: String? = nil
    }

    nonisolated enum Tint: Equatable, Sendable {
        case secondary, warning, success, failure
    }

    nonisolated enum TextStyle: Equatable, Sendable {
        case plain, monospaced
    }

    nonisolated struct TextBlock: Equatable, Sendable {
        var title: String?
        var text: String
        var style: TextStyle
    }

    nonisolated struct ListRow: Equatable, Sendable {
        var title: String
        var subtitle: String? = nil
        var detail: String? = nil
        var badges: [String] = []
        var symbol: String? = nil
        var tint: Tint = .secondary
        var url: String? = nil
    }

    nonisolated struct ListBlock: Equatable, Sendable {
        var title: String?
        var rows: [ListRow]
        var emptyMessage: String? = nil
    }

    nonisolated struct ListSection: Equatable, Sendable {
        var title: String
        var rows: [ListRow]
    }

    nonisolated struct GroupedList: Equatable, Sendable {
        var summary: String
        var sections: [ListSection]
        var isScrollable: Bool
    }
}

/// The complete, immutable input to a detail projection.
nonisolated struct AgentToolDetailInput: Sendable {
    var result: AgentJSONValue
    var arguments: [String: AgentJSONValue]
    var locale: Locale
}

/// A local function selected by a stable ID stored in descriptor metadata.
/// Only the built-in catalog constructs these; remote tools cannot register code.
nonisolated struct AgentToolDetailPresenter: Sendable {
    let id: String
    private let projection: @Sendable (AgentToolDetailInput) -> [AgentToolDetail.Item]

    init(
        id: String,
        present: @escaping @Sendable (AgentToolDetailInput) -> [AgentToolDetail.Item]
    ) {
        precondition(id.hasPrefix("builtin."), "Built-in detail presenter IDs must be namespaced")
        self.id = id
        projection = present
    }

    func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        projection(input)
    }
}

/// The only executable detail presenters the app trusts.
nonisolated enum AgentBuiltInToolDetailPresenters {
    static let all: [AgentToolDetailPresenter] = [
        AgentBuiltInTools.listHostsDetailPresenter,
        AgentBuiltInTools.sshExecDetailPresenter,
        AgentBuiltInTools.sshWaitDetailPresenter,
        AgentBuiltInTools.terminalSuggestDetailPresenter,
        AgentBuiltInTools.sftpListDetailPresenter,
        AgentBuiltInTools.sftpStatDetailPresenter,
        AgentBuiltInTools.sftpReadDetailPresenter,
        AgentBuiltInTools.sftpWriteDetailPresenter,
        AgentBuiltInTools.sftpMkdirDetailPresenter,
        AgentBuiltInTools.sftpMoveDetailPresenter,
        AgentBuiltInTools.sftpChmodDetailPresenter,
        AgentBuiltInTools.sftpDeleteDetailPresenter,
        AgentBuiltInTools.fetchDetailPresenter,
        AgentBuiltInTools.webSearchDetailPresenter,
        AgentBuiltInTools.requestUserInputDetailPresenter,
        AgentBuiltInTools.requestUserSecretDetailPresenter,
        AgentScratchTools.listDetailPresenter,
        AgentScratchTools.readDetailPresenter,
        AgentScratchTools.searchDetailPresenter,
        AgentScratchTools.writeDetailPresenter,
        AgentScratchTools.editDetailPresenter,
        AgentScratchTools.diffDetailPresenter,
        AgentScratchTools.deleteDetailPresenter,
        AgentScratchTools.pullDetailPresenter,
        AgentScratchTools.pushDetailPresenter,
        AgentScratchTools.fetchDetailPresenter,
        AgentPlanTools.presentPlanDetailPresenter,
        AgentPlanTools.manageTasksDetailPresenter,
    ]

    private static let byID: [String: AgentToolDetailPresenter] = {
        var result: [String: AgentToolDetailPresenter] = [:]
        for presenter in all {
            precondition(result[presenter.id] == nil, "Duplicate detail presenter ID: \(presenter.id)")
            result[presenter.id] = presenter
        }
        return result
    }()

    /// Names understood by releases that predate persisted presenter IDs.
    private static let legacyToolNames: Set<String> = [
        "list_hosts", "ssh_exec", "ssh_wait", "terminal_suggest",
        "sftp_list", "sftp_stat", "sftp_read", "sftp_write", "sftp_mkdir",
        "sftp_move", "sftp_chmod", "sftp_delete", "fetch", "web_search",
        "request_user_input", "request_user_secret", "scratch_list", "scratch_read",
        "scratch_write", "scratch_edit", "scratch_diff", "scratch_delete",
        "scratch_pull", "scratch_push", "present_plan", "manage_tasks",
    ]

    static var ids: [String] { all.map(\.id) }

    static func presenter(id: String) -> AgentToolDetailPresenter? { byID[id] }

    static func legacyPresenter(forToolNamed name: String) -> AgentToolDetailPresenter? {
        guard legacyToolNames.contains(name) else { return nil }
        return byID["builtin.\(name)"]
    }
}

/// Shared vocabulary for tool-owned projections. It owns generic formatting,
/// not knowledge of any particular result schema.
nonisolated enum AgentToolDetailFormatting {
    typealias Item = AgentToolDetail.Item
    typealias Field = AgentToolDetail.Field

    static func genericItems(
        _ value: AgentJSONValue, locale: Locale
    ) -> [AgentToolDetail.Item] {
        var fields: [Field] = []
        flatten(value, path: [], locale: locale, into: &fields)
        if fields.isEmpty {
            return [.message(localized("Completed without output", locale: locale), .secondary)]
        }
        return fields.map(Item.field)
    }

    private static func flatten(
        _ value: AgentJSONValue, path: [String], locale: Locale, into fields: inout [Field]
    ) {
        switch value {
        case .object(let object):
            for key in object.keys.sorted() {
                flatten(
                    object[key] ?? .null, path: path + [humanized(key)], locale: locale,
                    into: &fields
                )
            }
        case .array(let array):
            if array.isEmpty {
                fields.append(Field(
                    label: label(path, locale: locale), value: localized("None", locale: locale)
                ))
            } else {
                for (index, entry) in array.enumerated() {
                    flatten(
                        entry, path: path + [String(index + 1)], locale: locale, into: &fields
                    )
                }
            }
        case .string(let string):
            fields.append(Field(label: label(path, locale: locale), value: string))
        case .number(let number):
            let rendered = number.rounded() == number ? String(Int(number)) : String(number)
            fields.append(Field(label: label(path, locale: locale), value: rendered))
        case .bool(let bool):
            fields.append(Field(
                label: label(path, locale: locale),
                value: localized(bool ? "Yes" : "No", locale: locale)
            ))
        case .null:
            break
        }
    }

    static func field(
        _ label: String.LocalizationValue, _ value: String, locale: Locale,
        monospaced: Bool = false, url: String? = nil
    ) -> Item {
        .field(Field(
            label: AppLocalization.string(label, locale: locale), value: value,
            isMonospaced: monospaced, url: url
        ))
    }

    static func appendField(
        _ items: inout [Item], _ label: String.LocalizationValue, _ value: String?,
        locale: Locale, monospaced: Bool = false
    ) {
        guard let value = nonempty(value) else { return }
        items.append(field(label, value, locale: locale, monospaced: monospaced))
    }

    static func appendBytes(
        _ items: inout [Item], _ label: String.LocalizationValue, _ value: AgentJSONValue?,
        locale: Locale
    ) {
        guard let bytes = value?.integerValue else { return }
        items.append(field(label, byteCount(bytes), locale: locale))
    }

    static func text(
        _ title: String.LocalizationValue, _ value: String, locale: Locale
    ) -> Item {
        .text(.init(
            title: AppLocalization.string(title, locale: locale), text: value, style: .monospaced
        ))
    }

    static func localized(_ key: String.LocalizationValue, locale: Locale) -> String {
        AppLocalization.string(key, locale: locale)
    }

    static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    static func byteCount(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func displayDate(_ raw: String) -> String {
        guard let date = try? Date.ISO8601FormatStyle().parse(raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func statusLabel(_ status: String, locale: Locale) -> String {
        switch status {
        case "connecting": localized("Connecting", locale: locale)
        case "running": localized("Running", locale: locale)
        case "exited": localized("Exited", locale: locale)
        default: humanized(status).capitalized
        }
    }

    static func kindLabel(_ kind: String, locale: Locale) -> String {
        switch kind {
        case "file": localized("File", locale: locale)
        case "directory": localized("Directory", locale: locale)
        case "symlink", "symbolic_link": localized("Symlink", locale: locale)
        default: humanized(kind).capitalized
        }
    }

    static func humanized(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ")
    }

    private static func label(_ path: [String], locale: Locale) -> String {
        let rendered = path.joined(separator: " · ")
        return rendered.isEmpty ? localized("Result", locale: locale) : rendered.capitalized
    }
}
