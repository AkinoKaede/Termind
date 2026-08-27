import Foundation

/// Turns tool protocol data into the small amount of language the transcript needs.
/// Execution, approval and replay continue to use the original call and result unchanged.
nonisolated enum AgentToolPresentation {
    enum BatchTint: Equatable {
        case secondary, warning, success, failure
    }

    static let displayCharacterLimit = 8_192
    static let displayLineLimit = 120

    nonisolated struct OutputPreview: Equatable, Sendable {
        let displayed: String
        let full: String
        let isShortened: Bool
        let omittedCharacters: Int
    }

    nonisolated struct Detail: Equatable, Sendable {
        var items: [DetailItem]
    }

    nonisolated enum DetailItem: Equatable, Sendable {
        case field(DetailField)
        case message(String, DetailTint)
        case text(DetailTextBlock)
        case list(DetailListBlock)
        case groupedList(DetailGroupedList)
    }

    nonisolated struct DetailField: Equatable, Sendable {
        var label: String
        var value: String
        var isMonospaced = false
        var url: String? = nil
    }

    nonisolated enum DetailTint: Equatable, Sendable {
        case secondary, warning, success, failure
    }

    nonisolated enum DetailTextStyle: Equatable, Sendable {
        case plain, monospaced
    }

    nonisolated struct DetailTextBlock: Equatable, Sendable {
        var title: String?
        var text: String
        var style: DetailTextStyle
    }

    nonisolated struct DetailListRow: Equatable, Sendable {
        var title: String
        var subtitle: String? = nil
        var detail: String? = nil
        var badges: [String] = []
        var symbol: String? = nil
        var tint: DetailTint = .secondary
        var url: String? = nil
    }

    nonisolated struct DetailListBlock: Equatable, Sendable {
        var title: String?
        var rows: [DetailListRow]
        var emptyMessage: String? = nil
    }

    nonisolated struct DetailListSection: Equatable, Sendable {
        var title: String
        var rows: [DetailListRow]
    }

    nonisolated struct DetailGroupedList: Equatable, Sendable {
        var summary: String
        var sections: [DetailListSection]
        var isScrollable: Bool
    }

    static func symbol(for card: AgentToolCard) -> String {
        return card.descriptor.presentation?.symbol ?? "wrench.and.screwdriver"
    }

    /// While work is live, use the icon of the tool(s) still in flight. After
    /// completion, a homogeneous batch keeps its tool icon; mixed batches use
    /// the generic tools symbol.
    static func batchSymbol(for cards: [AgentToolCard]) -> String {
        let unfinished = cards.filter { !$0.state.isTerminal }
        if let live = unfinished.first { return symbol(for: live) }
        guard let first = cards.first else { return "wrench.and.screwdriver" }
        let name = first.descriptor.qualifiedName
        return cards.allSatisfy { $0.descriptor.qualifiedName == name }
            ? symbol(for: first) : "wrench.and.screwdriver"
    }

    static func batchTint(for cards: [AgentToolCard]) -> BatchTint {
        if let live = cards.first(where: { !$0.state.isTerminal }) {
            return tint(for: live.state)
        }
        if !cards.isEmpty, cards.allSatisfy({ $0.state == .completed }) {
            return .success
        }
        if !cards.isEmpty, cards.allSatisfy({ $0.state == .failed || $0.state == .denied }) {
            return .failure
        }
        return .warning
    }

    /// A stable 30% sample for a batch. Invocation identifiers are random UUIDs,
    /// so using their first 32 bits gives the desired distribution without
    /// making a SwiftUI row redraw or scroll reuse roll the dice again.
    static func showsReasoning(forBatchID id: UUID) -> Bool {
        let sample = withUnsafeBytes(of: id.uuid) { bytes in
            bytes.prefix(4).reduce(UInt32.zero) { value, byte in
                (value << 8) | UInt32(byte)
            }
        }
        return sample < (UInt32.max / 10) * 3
    }

    /// Converts provider-authored Markdown into the one-line prose a tool
    /// batch header can accommodate. Structure and emphasis remain available
    /// in the live reasoning row; here only the visible words are reused.
    static func reasoningTitle(from markdown: String) -> String {
        let text = MarkdownDocumentParser.parse(markdown)
            .flatMap(plainText)
            .joined(separator: " ")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func summary(
        for card: AgentToolCard,
        hostName: String? = nil
    ) -> String {
        let operation = operationName(for: card)
        let phase: String
        if card.state == .running {
            phase = card.result?.presentationPhase ?? card.state.rawValue
        } else if card.state == .reviewing {
            phase = AgentToolCard.State.proposed.rawValue
        } else {
            phase = card.state.rawValue
        }
        if let template = card.descriptor.presentation?.messages[phase] {
            var rendered = template.replacingOccurrences(of: "{activity}", with: operation)
            if let hostName, !hostName.isEmpty {
                rendered = rendered.replacingOccurrences(of: "{target}", with: hostName)
            } else {
                // A host-shaped tool is not necessarily tied to one server. In
                // particular, list_hosts and ssh_wait are not; a rejected call
                // can also fail before its host_id becomes a resolved target.
                rendered = rendered.replacingOccurrences(of: " on {target}", with: "")
                rendered = rendered.replacingOccurrences(of: " to {target}", with: "")
                rendered = rendered.replacingOccurrences(of: " with {target}", with: "")
                rendered = rendered.replacingOccurrences(of: "{target}", with: "")
            }
            return rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let action: String
        switch card.state {
        case .proposed: action = String(localized: "Preparing \(operation)")
        case .waitingForApproval: action = String(localized: "Waiting to run \(operation)")
        case .waitingForUser: action = String(localized: "Waiting to run \(operation)")
        case .reviewing: action = String(localized: "Preparing \(operation)")
        case .running: action = String(localized: "Running \(operation)")
        case .completed: action = String(localized: "Ran \(operation)")
        case .denied: action = String(localized: "Denied \(operation)")
        case .failed: action = String(localized: "Failed \(operation)")
        case .interrupted: action = String(localized: "Interrupted \(operation)")
        }

        if let hostName, !hostName.isEmpty { return String(localized: "\(action) on \(hostName)") }
        return action
    }

    private static func plainText(_ block: MarkdownBlock) -> [String] {
        switch block {
        case .paragraph(let inlines), .heading(_, let inlines):
            [inlines.map(\.text).joined()]
        case .codeBlock(_, let code):
            [code]
        case .list(let list):
            list.items.flatMap { $0.blocks.flatMap(plainText) }
        case .table(let table):
            ([table.header] + table.rows).flatMap { row in
                row.map { $0.map(\.text).joined() }
            }
        case .blockQuote(let blocks):
            blocks.flatMap(plainText)
        case .htmlBlock(let raw):
            [raw]
        case .thematicBreak:
            []
        }
    }

    /// A finished contiguous batch, phrased from the same presentation
    /// metadata as its individual rows but with repeated activities counted.
    /// Calls in different terminal states stay separate, so one failure can
    /// never be rewritten as a successful action by the batch title.
    static func batchSummary(for cards: [AgentToolCard]) -> String {
        struct Key: Hashable {
            let name: String
            let state: AgentToolCard.State
        }

        var order: [Key] = []
        var grouped: [Key: [AgentToolCard]] = [:]
        for card in cards {
            let key = Key(name: card.descriptor.qualifiedName, state: card.state)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(card)
        }
        return order.compactMap { grouped[$0].map(batchClause) }
            .enumerated()
            .map { index, clause in index == 0 ? clause : lowercaseFirst(clause) }
            .joined(separator: ", ")
    }

    static func output(from result: AgentToolResult) -> String {
        let raw = result.untrustedPayload ?? result.content
        return output(raw, policy: .automatic)
    }

    static func output(from result: AgentToolResult, presentation: AgentToolDescriptor.Presentation?) -> String {
        let raw = result.untrustedPayload ?? result.content
        return output(raw, policy: presentation?.output ?? .automatic)
    }

    /// The denial reason is intentionally kept both on the review record and
    /// in the tool result: people need the former and the model must receive
    /// the latter. The transcript, however, should not print identical text
    /// twice. Distinct execution failures remain visible below the review.
    static func detailOutput(
        from result: AgentToolResult,
        presentation: AgentToolDescriptor.Presentation?,
        review: SecurityReviewDecision?
    ) -> String? {
        let rendered = output(from: result, presentation: presentation)
        guard result.isError, let review, !review.allowsExecution,
            normalized(rendered) == normalized(review.reason)
        else { return rendered }
        return nil
    }

    /// Projects protocol-shaped tool results into transcript-shaped content.
    /// The model and persistence keep the original JSON; only this projection
    /// is allowed to decide what a person sees.
    static func detail(for card: AgentToolCard) -> Detail? {
        guard let result = card.result else { return nil }

        // MCP output is remote-defined and intentionally keeps the established
        // JSON presentation. Built-ins below never fall back to JSON syntax.
        if card.descriptor.target == .mcp {
            guard let output = detailOutput(
                from: result, presentation: card.descriptor.presentation,
                review: card.review
            ) else { return nil }
            return Detail(items: [
                .text(DetailTextBlock(title: nil, text: output, style: .monospaced))
            ])
        }

        let raw = result.untrustedPayload ?? result.content
        guard let value = try? AgentJSONValue.decode(Data(raw.utf8)) else {
            guard let output = detailOutput(
                from: result, presentation: card.descriptor.presentation,
                review: card.review
            ) else { return nil }
            let text = output.isEmpty ? String(localized: "Completed without output") : output
            return Detail(items: [
                .message(text, result.isError ? .failure : .secondary)
            ])
        }

        let arguments = card.invocation.call.arguments.objectValue ?? [:]
        let items: [DetailItem]? = switch card.descriptor.name {
        case "list_hosts": hostListing(value)
        case "ssh_exec", "ssh_wait": commandResult(value)
        case "terminal_suggest": terminalSuggestion(value, arguments: arguments)
        case "sftp_list": remoteFileList(value)
        case "sftp_stat": remoteFileStat(value)
        case "sftp_read": contentResult(value, title: String(localized: "Content"), includesPath: true)
        case "sftp_write": sftpWrite(value, arguments: arguments)
        case "sftp_mkdir": pathResult(value, result: String(localized: "Directory created"))
        case "sftp_move": moveResult(value)
        case "sftp_chmod": chmodResult(value)
        case "sftp_delete": deleteResult(value, arguments: arguments)
        case "fetch": fetchResult(value, arguments: arguments)
        case "web_search": webSearchResult(value)
        case "request_user_input": userInputResult(value, arguments: arguments)
        case "request_user_secret": secretResult(arguments: arguments)
        case "scratch_list": scratchList(value)
        case "scratch_read": scratchRead(value)
        case "scratch_write": scratchWrite(value)
        case "scratch_edit": scratchEdit(value)
        case "scratch_diff": scratchDiff(value)
        case "scratch_delete": scratchDelete(value)
        case "scratch_pull": scratchPull(value)
        case "scratch_push": scratchPush(value)
        case "present_plan": presentPlan(value)
        case "manage_tasks": taskResult(value)
        default: nil
        }

        if let items { return Detail(items: items) }
        return Detail(items: genericItems(value))
    }

    // MARK: - Built-in detail projections

    private struct HostGroupProjection {
        let id: String
        let title: String
    }

    private static func hostListing(_ value: AgentJSONValue) -> [DetailItem] {
        guard let object = value.objectValue else { return genericItems(value) }
        let hostValues = object["hosts"]?.arrayValue ?? []
        let groupValues = object["groups"]?.arrayValue ?? []
        var groups: [HostGroupProjection] = []

        func walk(_ rows: [AgentJSONValue], prefix: String = "") {
            for row in rows {
                guard let fields = row.objectValue else { continue }
                let name = nonempty(fields["name"]?.stringValue) ?? String(localized: "Unnamed group")
                let computed = prefix.isEmpty ? name : "\(prefix) / \(name)"
                let title = nonempty(fields["path"]?.stringValue) ?? computed
                if let id = fields["id"]?.stringValue {
                    groups.append(HostGroupProjection(id: id, title: title))
                }
                walk(fields["children"]?.arrayValue ?? [], prefix: computed)
            }
        }
        walk(groupValues)

        var grouped: [String: [DetailListRow]] = [:]
        var ungrouped: [DetailListRow] = []
        var temporary: [DetailListRow] = []
        var connected = 0

        for hostValue in hostValues {
            guard let host = hostValue.objectValue else { continue }
            let state = host["connection_state"]?.stringValue ?? ""
            if state == "connected" { connected += 1 }
            let row = hostRow(host)
            if host["temporary"]?.boolValue == true {
                temporary.append(row)
            } else if let groupID = host["group_id"]?.stringValue,
                groups.contains(where: { $0.id == groupID })
            {
                grouped[groupID, default: []].append(row)
            } else {
                ungrouped.append(row)
            }
        }

        guard !hostValues.isEmpty || !groups.isEmpty else {
            return [.message(String(localized: "No hosts available"), .secondary)]
        }

        var summaryParts = [hostCount(hostValues.count)]
        if connected > 0 { summaryParts.append(String(localized: "\(connected) connected")) }
        if !temporary.isEmpty {
            summaryParts.append(String(localized: "\(temporary.count) temporary"))
        }
        var sections = groups.map { group in
            let rows = grouped[group.id] ?? []
            return DetailListSection(
                title: "\(group.title) · \(hostCount(rows.count))", rows: rows
            )
        }
        if !groups.isEmpty || !ungrouped.isEmpty {
            sections.append(DetailListSection(
                title: "\(String(localized: "Ungrouped")) · \(hostCount(ungrouped.count))",
                rows: ungrouped
            ))
        }
        if !temporary.isEmpty {
            sections.append(DetailListSection(
                title: "\(String(localized: "Temporary")) · \(hostCount(temporary.count))",
                rows: temporary
            ))
        }
        return [.groupedList(DetailGroupedList(
            summary: summaryParts.joined(separator: " · "), sections: sections,
            isScrollable: hostValues.count > 12
        ))]
    }

    private static func hostRow(_ host: [String: AgentJSONValue]) -> DetailListRow {
        let address = nonempty(host["address"]?.stringValue)
        let name = nonempty(host["display_name"]?.stringValue)
            ?? address ?? String(localized: "Unnamed host")
        let state = host["connection_state"]?.stringValue ?? ""
        let statePresentation = connectionState(state)
        let subtitle = [address ?? String(localized: "Address unavailable"), statePresentation.label]
            .joined(separator: " · ")
        let tags = host["tags"]?.arrayValue?.compactMap { nonempty($0.stringValue) } ?? []
        return DetailListRow(
            title: name, subtitle: subtitle, badges: tags, symbol: "circle.fill",
            tint: statePresentation.tint
        )
    }

    private static func connectionState(_ raw: String) -> (label: String, tint: DetailTint) {
        switch raw {
        case "connected": (String(localized: "Connected"), .success)
        case "connecting": (String(localized: "Connecting"), .warning)
        case "reconnecting": (String(localized: "Reconnecting"), .warning)
        case "disconnected": (String(localized: "Not connected"), .secondary)
        case "failed": (String(localized: "Failed"), .failure)
        default: (
            nonempty(humanized(raw))?.capitalized ?? String(localized: "Unknown"), .secondary
        )
        }
    }

    private static func commandResult(_ value: AgentJSONValue) -> [DetailItem] {
        guard let object = value.objectValue else { return genericItems(value) }
        var items: [DetailItem] = []
        if let status = object["status"]?.stringValue {
            items.append(field("Status", statusLabel(status)))
        }
        if let code = object["exit_code"]?.integerValue {
            items.append(field("Exit code", String(code), monospaced: true))
        }
        if let signal = nonempty(object["signal"]?.stringValue) {
            items.append(field("Signal", signal, monospaced: true))
        }
        let stdout = object["stdout"]?.stringValue ?? ""
        let stderr = object["stderr"]?.stringValue ?? ""
        if !stdout.isEmpty { items.append(text("Standard output", stdout)) }
        if !stderr.isEmpty { items.append(text("Standard error", stderr)) }
        if stdout.isEmpty, stderr.isEmpty, object["note"] == nil {
            items.append(.message(String(localized: "No output"), .secondary))
        }
        if let note = nonempty(object["note"]?.stringValue) {
            items.append(.message(note, .warning))
        }
        return items
    }

    private static func terminalSuggestion(
        _ value: AgentJSONValue, arguments: [String: AgentJSONValue]
    ) -> [DetailItem] {
        let object = value.objectValue ?? [:]
        let command = arguments["command"]?.stringValue ?? object["command"]?.stringValue ?? ""
        var items: [DetailItem] = [text("Command", command)]
        if let explanation = nonempty(
            arguments["explanation"]?.stringValue ?? object["explanation"]?.stringValue
        ) {
            items.append(.message(explanation, .secondary))
        }
        let assessment = CommandRiskClassifier.assess(command)
        items.append(field("Risk", assessment.risk.label))
        items.append(contentsOf: assessment.reasons.map { .message($0, .warning) })
        items.append(.message(String(localized: "Requires user action"), .warning))
        return items
    }

    private static func remoteFileList(_ value: AgentJSONValue) -> [DetailItem] {
        guard let rows = value.arrayValue else { return genericItems(value) }
        let items = rows.compactMap(remoteFileRow)
        return [
            .message(itemCount(items.count), .secondary),
            .list(DetailListBlock(
                title: nil, rows: items,
                emptyMessage: String(localized: "Directory is empty")
            )),
        ]
    }

    private static func remoteFileRow(_ value: AgentJSONValue) -> DetailListRow? {
        guard let object = value.objectValue else { return nil }
        let path = object["path"]?.stringValue ?? ""
        let name = nonempty(object["name"]?.stringValue)
            ?? nonempty(path.split(separator: "/").last.map(String.init))
            ?? String(localized: "Unnamed item")
        let kind = object["kind"]?.stringValue ?? ""
        var metadata = [humanized(kind).capitalized]
        if let bytes = object["size"]?.integerValue { metadata.append(byteCount(bytes)) }
        if let permissions = nonempty(object["permissions"]?.stringValue) {
            metadata.append(permissions)
        }
        let modified = object["modified_at"]?.stringValue.map(displayDate)
        return DetailListRow(
            title: name, subtitle: metadata.filter { !$0.isEmpty }.joined(separator: " · "),
            detail: modified, symbol: kind == "directory" ? "folder" : "doc"
        )
    }

    private static func remoteFileStat(_ value: AgentJSONValue) -> [DetailItem] {
        guard let object = value.objectValue else { return genericItems(value) }
        var items: [DetailItem] = []
        appendField(&items, "Path", object["path"]?.stringValue, monospaced: true)
        appendField(&items, "Kind", object["kind"]?.stringValue.map { humanized($0).capitalized })
        if let bytes = object["size"]?.integerValue { items.append(field("Size", byteCount(bytes))) }
        appendField(&items, "Permissions", object["permissions"]?.stringValue, monospaced: true)
        appendField(&items, "Modified", object["modified_at"]?.stringValue.map(displayDate))
        return items
    }

    private static func contentResult(
        _ value: AgentJSONValue, title: String, includesPath: Bool
    ) -> [DetailItem] {
        guard let object = value.objectValue else { return genericItems(value) }
        var items: [DetailItem] = []
        if includesPath { appendField(&items, "Path", object["path"]?.stringValue, monospaced: true) }
        let content = object["content"]?.stringValue ?? ""
        items.append(content.isEmpty
            ? .message(String(localized: "Empty file"), .secondary)
            : .text(DetailTextBlock(title: title, text: content, style: .monospaced)))
        if let bytes = object["bytes"]?.integerValue { items.append(field("Size", byteCount(bytes))) }
        return items
    }

    private static func sftpWrite(
        _ value: AgentJSONValue, arguments: [String: AgentJSONValue]
    ) -> [DetailItem] {
        guard let object = value.objectValue else { return genericItems(value) }
        var items: [DetailItem] = []
        appendField(&items, "Path", object["path"]?.stringValue, monospaced: true)
        if let content = arguments["content"]?.stringValue {
            items.append(field("Size", byteCount(content.utf8.count)))
        }
        items.append(field("Result", String(localized: "Written")))
        return items
    }

    private static func pathResult(_ value: AgentJSONValue, result: String) -> [DetailItem] {
        guard let object = value.objectValue else { return genericItems(value) }
        var items: [DetailItem] = []
        appendField(&items, "Path", object["path"]?.stringValue, monospaced: true)
        items.append(field("Result", result))
        return items
    }

    private static func moveResult(_ value: AgentJSONValue) -> [DetailItem] {
        guard let object = value.objectValue else { return genericItems(value) }
        var items: [DetailItem] = []
        appendField(&items, "From", object["source"]?.stringValue, monospaced: true)
        appendField(&items, "To", object["destination"]?.stringValue, monospaced: true)
        return items
    }

    private static func chmodResult(_ value: AgentJSONValue) -> [DetailItem] {
        guard let object = value.objectValue else { return genericItems(value) }
        var items: [DetailItem] = []
        appendField(&items, "Path", object["path"]?.stringValue, monospaced: true)
        appendField(&items, "Permissions", object["mode"]?.stringValue, monospaced: true)
        return items
    }

    private static func deleteResult(
        _ value: AgentJSONValue, arguments: [String: AgentJSONValue]
    ) -> [DetailItem] {
        guard let object = value.objectValue else { return genericItems(value) }
        var items: [DetailItem] = []
        appendField(&items, "Path", object["path"]?.stringValue, monospaced: true)
        appendField(&items, "Kind", arguments["kind"]?.stringValue.map { humanized($0).capitalized })
        items.append(field("Result", String(localized: "Deleted")))
        return items
    }

    private static func fetchResult(
        _ value: AgentJSONValue, arguments: [String: AgentJSONValue]
    ) -> [DetailItem] {
        guard let object = value.objectValue else { return genericItems(value) }
        var items: [DetailItem] = []
        if let url = nonempty(object["url"]?.stringValue) {
            items.append(.field(DetailField(
                label: String(localized: "URL"), value: url, isMonospaced: true, url: url
            )))
        }
        if let status = object["status"]?.integerValue {
            items.append(field("Status", String(status)))
        }
        if let headers = object["headers"]?.objectValue, !headers.isEmpty {
            let rows = headers.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .map { name in
                    DetailListRow(title: name, subtitle: headers[name]?.stringValue ?? "")
                }
            items.append(.list(DetailListBlock(
                title: String(localized: "Response headers"), rows: rows
            )))
        }
        let method = arguments["method"]?.stringValue ?? "GET"
        if method != "HEAD" {
            let body = object["body"]?.stringValue ?? ""
            items.append(body.isEmpty
                ? .message(String(localized: "Empty response body"), .secondary)
                : .text(DetailTextBlock(
                    title: String(localized: "Response body"), text: body, style: .plain
                )))
        }
        return items
    }

    private static func webSearchResult(_ value: AgentJSONValue) -> [DetailItem] {
        guard let values = value.arrayValue else { return genericItems(value) }
        let rows = values.compactMap { entry -> DetailListRow? in
            guard let object = entry.objectValue else { return nil }
            let url = nonempty(object["url"]?.stringValue)
            let title = nonempty(object["title"]?.stringValue) ?? url
                ?? String(localized: "Untitled result")
            let snippet = nonempty(object["snippet"]?.stringValue)
            let published = object["published_at"]?.stringValue.map(displayDate)
            return DetailListRow(
                title: title, subtitle: url, detail: [snippet, published].compactMap { $0 }
                    .joined(separator: "\n"), symbol: "link", url: url
            )
        }
        return [
            .message(searchResultCount(rows.count), .secondary),
            .list(DetailListBlock(
                title: nil, rows: rows, emptyMessage: String(localized: "No results")
            )),
        ]
    }

    private static func userInputResult(
        _ value: AgentJSONValue, arguments: [String: AgentJSONValue]
    ) -> [DetailItem] {
        guard let answers = value.objectValue?["answers"]?.arrayValue else {
            return genericItems(value)
        }
        let answerByID = Dictionary(
            answers.compactMap { row -> (String, [String: AgentJSONValue])? in
                guard let fields = row.objectValue,
                    let id = fields["question_id"]?.stringValue
                else { return nil }
                return (id, fields)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let questions = arguments["questions"]?.arrayValue ?? []
        var items: [DetailItem] = []
        for questionValue in questions {
            guard let question = questionValue.objectValue else { continue }
            let id = question["id"]?.stringValue ?? ""
            let prompt = question["prompt"]?.stringValue ?? String(localized: "Question unavailable")
            let header = nonempty(question["header"]?.stringValue)
            let displayedQuestion = header.map { "\($0) — \(prompt)" } ?? prompt
            let answerFields = answerByID[id]
            let answer = answerFields?["answer"]
            let displayedAnswer: String
            if let answer, answer != .null {
                let selected = answerFields?["selected_option_ids"]?.arrayValue?
                    .compactMap(\.stringValue) ?? []
                let selectedSet = Set(selected)
                let labels = question["options"]?.arrayValue?.compactMap { option -> String? in
                    guard let fields = option.objectValue,
                        let optionID = fields["id"]?.stringValue,
                        selectedSet.contains(optionID)
                    else { return nil }
                    return nonempty(fields["label"]?.stringValue)
                } ?? []
                let custom = nonempty(answerFields?["custom_text"]?.stringValue)
                let structured = labels + [custom].compactMap { $0 }
                displayedAnswer = structured.isEmpty
                    ? nonempty(answer.stringValue) ?? String(localized: "Skipped")
                    : structured.joined(separator: ", ")
            } else {
                displayedAnswer = String(localized: "Skipped")
            }
            items.append(field("Question", displayedQuestion))
            items.append(field("Answer", displayedAnswer))
        }
        return items.isEmpty ? genericItems(value) : items
    }

    private static func secretResult(arguments: [String: AgentJSONValue]) -> [DetailItem] {
        var items: [DetailItem] = []
        appendField(&items, "Request", arguments["prompt"]?.stringValue)
        appendField(&items, "Purpose", arguments["purpose"]?.stringValue)
        if arguments["consumer_tool"]?.stringValue == "ssh_exec" {
            items.append(field("Consumer", String(localized: "SSH command")))
        } else {
            appendField(&items, "Consumer", arguments["consumer_tool"]?.stringValue.map(humanized))
        }
        items.append(field("Status", String(localized: "Secret received securely")))
        return items
    }

    private static func scratchList(_ value: AgentJSONValue) -> [DetailItem] {
        guard let object = value.objectValue else { return genericItems(value) }
        let entries = object["entries"]?.arrayValue ?? []
        let entryCount = object["entry_count"]?.integerValue ?? entries.count
        let entryQuota = object["entry_quota"]?.integerValue
        let totalBytes = object["total_bytes"]?.integerValue ?? 0
        let byteQuota = object["byte_quota"]?.integerValue
        var summary = entryQuota.map { "\(entryCount) / \($0) entries" }
            ?? String(localized: "\(entryCount) entries")
        if let byteQuota {
            summary += " · \(byteCount(totalBytes)) / \(byteCount(byteQuota))"
        } else {
            summary += " · \(byteCount(totalBytes))"
        }
        let rows = entries.compactMap { entry -> DetailListRow? in
            guard let fields = entry.objectValue else { return nil }
            let path = fields["path"]?.stringValue ?? String(localized: "Unnamed entry")
            let kind = fields["kind"]?.stringValue ?? ""
            var subtitle = humanized(kind).capitalized
            if let bytes = fields["bytes"]?.integerValue { subtitle += " · \(byteCount(bytes))" }
            return DetailListRow(
                title: path, subtitle: subtitle,
                detail: fields["modified_at"]?.stringValue.map(displayDate),
                symbol: kind == "directory" ? "folder" : "doc"
            )
        }
        return [
            .message(summary, .secondary),
            .list(DetailListBlock(
                title: nil, rows: rows, emptyMessage: String(localized: "Workspace is empty")
            )),
        ]
    }

    private static func scratchRead(_ value: AgentJSONValue) -> [DetailItem] {
        guard let object = value.objectValue else { return genericItems(value) }
        var items: [DetailItem] = []
        appendField(&items, "Path", object["path"]?.stringValue, monospaced: true)
        let content = object["content"]?.stringValue ?? ""
        items.append(content.isEmpty
            ? .message(String(localized: "Empty file"), .secondary)
            : text("Content", content))
        if let offset = object["offset"]?.integerValue,
            let returned = object["returned_lines"]?.integerValue,
            let total = object["total_lines"]?.integerValue
        {
            let start = returned == 0 ? offset : offset
            let end = returned == 0 ? offset : offset + returned - 1
            items.append(field("Lines", "\(start)–\(end) of \(total)"))
        }
        if let bytes = object["bytes"]?.integerValue { items.append(field("Size", byteCount(bytes))) }
        appendField(&items, "Line endings", object["line_ending"]?.stringValue?.uppercased())
        return items
    }

    private static func scratchWrite(_ value: AgentJSONValue) -> [DetailItem] {
        guard let object = value.objectValue else { return genericItems(value) }
        var items: [DetailItem] = []
        appendField(&items, "Path", object["path"]?.stringValue, monospaced: true)
        let outcome = object["created"]?.boolValue == true
            ? String(localized: "Created") : String(localized: "Overwritten")
        items.append(field("Result", outcome))
        appendBytes(&items, "Size", object["bytes"])
        appendField(&items, "SHA-256", object["sha256"]?.stringValue, monospaced: true)
        appendBytes(&items, "Workspace usage", object["total_bytes"])
        return items
    }

    private static func scratchEdit(_ value: AgentJSONValue) -> [DetailItem] {
        guard let object = value.objectValue else { return genericItems(value) }
        var items: [DetailItem] = []
        appendField(&items, "Path", object["path"]?.stringValue, monospaced: true)
        if let count = object["edits_applied"]?.integerValue {
            items.append(field("Changes", String(localized: "\(count) edits applied")))
        }
        if let diff = object["diff"]?.stringValue, !diff.isEmpty { items.append(text("Diff", diff)) }
        appendBytes(&items, "Size", object["bytes"])
        appendField(&items, "Line endings", object["line_ending"]?.stringValue?.uppercased())
        appendField(&items, "SHA-256", object["sha256"]?.stringValue, monospaced: true)
        appendBytes(&items, "Workspace usage", object["total_bytes"])
        return items
    }

    private static func scratchDiff(_ value: AgentJSONValue) -> [DetailItem] {
        guard let object = value.objectValue else { return genericItems(value) }
        var items: [DetailItem] = []
        appendField(&items, "From", object["path_a"]?.stringValue, monospaced: true)
        appendField(&items, "To", object["path_b"]?.stringValue, monospaced: true)
        let diff = object["diff"]?.stringValue ?? ""
        let a = object["line_ending_a"]?.stringValue?.uppercased()
        let b = object["line_ending_b"]?.stringValue?.uppercased()
        if !diff.isEmpty {
            items.append(text("Diff", diff))
        } else if object["identical"]?.boolValue == true {
            items.append(.message(String(localized: "Files are identical"), .success))
        } else if let a, let b, a != b {
            items.append(.message(
                String(localized: "Text is identical; line endings differ: \(a) → \(b)"),
                .warning
            ))
        } else {
            items.append(.message(String(localized: "No differences"), .secondary))
        }
        return items
    }

    private static func scratchDelete(_ value: AgentJSONValue) -> [DetailItem] {
        guard let object = value.objectValue else { return genericItems(value) }
        var items = pathResult(value, result: String(localized: "Deleted"))
        appendField(&items, "Kind", object["kind"]?.stringValue.map { humanized($0).capitalized })
        let count = object["entry_count"]?.integerValue
        let bytes = object["total_bytes"]?.integerValue
        if count != nil || bytes != nil {
            let parts = [count.map { String(localized: "\($0) entries") }, bytes.map(byteCount)]
                .compactMap { $0 }
            items.append(field("Workspace", parts.joined(separator: " · ")))
        }
        return items
    }

    private static func scratchPull(_ value: AgentJSONValue) -> [DetailItem] {
        guard let object = value.objectValue else { return genericItems(value) }
        var items: [DetailItem] = []
        appendField(&items, "Remote path", object["remote_path"]?.stringValue, monospaced: true)
        appendField(&items, "Scratch path", object["scratch_path"]?.stringValue, monospaced: true)
        appendBytes(&items, "Size", object["bytes"])
        items.append(field(
            "Content type",
            object["is_utf8"]?.boolValue == true
                ? String(localized: "UTF-8 text") : String(localized: "Binary")
        ))
        if let lines = object["lines"]?.integerValue { items.append(field("Lines", String(lines))) }
        appendField(&items, "SHA-256", object["sha256"]?.stringValue, monospaced: true)
        appendBytes(&items, "Workspace usage", object["total_bytes"])
        return items
    }

    private static func scratchPush(_ value: AgentJSONValue) -> [DetailItem] {
        guard let object = value.objectValue else { return genericItems(value) }
        var items: [DetailItem] = []
        appendField(&items, "Scratch path", object["scratch_path"]?.stringValue, monospaced: true)
        appendField(&items, "Remote path", object["remote_path"]?.stringValue, monospaced: true)
        appendBytes(&items, "Size", object["bytes"])
        appendField(&items, "SHA-256", object["sha256"]?.stringValue, monospaced: true)
        items.append(field("Result", String(localized: "Written")))
        return items
    }

    private static func presentPlan(_ value: AgentJSONValue) -> [DetailItem] {
        guard let path = value.objectValue?["scratch_path"]?.stringValue else {
            return genericItems(value)
        }
        return [.message(String(localized: "Plan presented from \(path)"), .success)]
    }

    private static func taskResult(_ value: AgentJSONValue) -> [DetailItem] {
        guard let object = value.objectValue,
            let total = object["tasks"]?.integerValue,
            let completed = object["completed"]?.integerValue
        else { return genericItems(value) }
        return [.message(
            String(localized: "\(total) tasks · \(completed) completed"), .secondary
        )]
    }

    // MARK: - Generic human-readable fallback

    private static func genericItems(_ value: AgentJSONValue) -> [DetailItem] {
        var fields: [DetailField] = []
        flatten(value, path: [], into: &fields)
        if fields.isEmpty {
            return [.message(String(localized: "Completed without output"), .secondary)]
        }
        return fields.map(DetailItem.field)
    }

    private static func flatten(
        _ value: AgentJSONValue, path: [String], into fields: inout [DetailField]
    ) {
        switch value {
        case .object(let object):
            for key in object.keys.sorted() {
                flatten(object[key] ?? .null, path: path + [humanized(key)], into: &fields)
            }
        case .array(let array):
            if array.isEmpty {
                fields.append(DetailField(label: label(path), value: String(localized: "None")))
            } else {
                for (index, entry) in array.enumerated() {
                    flatten(entry, path: path + [String(index + 1)], into: &fields)
                }
            }
        case .string(let string):
            fields.append(DetailField(label: label(path), value: string))
        case .number(let number):
            let rendered = number.rounded() == number ? String(Int(number)) : String(number)
            fields.append(DetailField(label: label(path), value: rendered))
        case .bool(let bool):
            fields.append(DetailField(
                label: label(path), value: bool ? String(localized: "Yes") : String(localized: "No")
            ))
        case .null:
            break
        }
    }

    private static func field(
        _ label: LocalizedStringResource, _ value: String, monospaced: Bool = false,
        url: String? = nil
    ) -> DetailItem {
        .field(DetailField(
            label: String(localized: label), value: value, isMonospaced: monospaced, url: url
        ))
    }

    private static func appendField(
        _ items: inout [DetailItem], _ label: LocalizedStringResource, _ value: String?,
        monospaced: Bool = false
    ) {
        guard let value = nonempty(value) else { return }
        items.append(field(label, value, monospaced: monospaced))
    }

    private static func appendBytes(
        _ items: inout [DetailItem], _ label: LocalizedStringResource, _ value: AgentJSONValue?
    ) {
        guard let bytes = value?.integerValue else { return }
        items.append(field(label, byteCount(bytes)))
    }

    private static func text(_ title: LocalizedStringResource, _ value: String) -> DetailItem {
        .text(DetailTextBlock(
            title: String(localized: title), text: value, style: .monospaced
        ))
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func byteCount(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private static func displayDate(_ raw: String) -> String {
        guard let date = try? Date.ISO8601FormatStyle().parse(raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func statusLabel(_ status: String) -> String {
        switch status {
        case "connecting": String(localized: "Connecting")
        case "running": String(localized: "Running")
        case "exited": String(localized: "Exited")
        default: humanized(status).capitalized
        }
    }

    private static func hostCount(_ count: Int) -> String {
        String(localized: "\(count) hosts")
    }

    private static func itemCount(_ count: Int) -> String {
        String(localized: "\(count) items")
    }

    private static func searchResultCount(_ count: Int) -> String {
        String(localized: "\(count) results")
    }

    private static func label(_ path: [String]) -> String {
        let rendered = path.joined(separator: " · ")
        return rendered.isEmpty ? String(localized: "Result") : rendered.capitalized
    }

    /// A bounded rendering projection. The full transformed output stays beside
    /// it for Copy, while the Text view only receives the small preview.
    static func preview(
        _ full: String,
        characterLimit: Int = displayCharacterLimit,
        lineLimit: Int = displayLineLimit
    ) -> OutputPreview {
        let lineCount = full.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        guard full.count > characterLimit || lineCount > lineLimit else {
            return OutputPreview(
                displayed: full, full: full, isShortened: false, omittedCharacters: 0
            )
        }

        // Five eighths at the front and three eighths at the back keeps the
        // command and initial diagnostics while retaining the final failure.
        // Leave room for the marker itself; a final tightening pass below
        // makes the bound exact even when the omitted count has many digits.
        let contentCharacterLimit = max(2, characterLimit - min(80, characterLimit / 4))
        let headCharacters = max(1, contentCharacterLimit * 5 / 8)
        let tailCharacters = max(1, contentCharacterLimit - headCharacters)
        let contentLineLimit = max(2, lineLimit - 1)
        let headLines = max(1, contentLineLimit * 5 / 8)
        let tailLines = max(1, contentLineLimit - headLines)

        let headByCharacters = full.index(
            full.startIndex,
            offsetBy: min(headCharacters, full.count)
        )
        let tailByCharacters = full.index(
            full.endIndex,
            offsetBy: -min(tailCharacters, full.count)
        )
        let headByLines = boundaryAfterLines(headLines, in: full)
        let tailByLines = boundaryBeforeLastLines(tailLines, in: full)
        var headEnd = min(headByCharacters, headByLines)
        var tailStart = max(tailByCharacters, tailByLines)

        // The limits above normally leave a gap. Keep the fallback defensive
        // for tiny custom limits used by unit tests.
        tailStart = max(tailStart, headEnd)
        var displayed = renderedPreview(full, headEnd: headEnd, tailStart: tailStart)
        while displayed.count > characterLimit, headEnd > full.startIndex || tailStart < full.endIndex {
            let overflow = displayed.count - characterLimit
            let availableHead = full.distance(from: full.startIndex, to: headEnd)
            let availableTail = full.distance(from: tailStart, to: full.endIndex)
            let dropHead = min(availableHead, max(1, overflow * 5 / 8))
            let dropTail = min(availableTail, max(0, overflow - dropHead))
            headEnd = full.index(headEnd, offsetBy: -dropHead)
            tailStart = full.index(tailStart, offsetBy: dropTail)
            displayed = renderedPreview(full, headEnd: headEnd, tailStart: tailStart)
        }
        let omitted = full.distance(from: headEnd, to: tailStart)
        return OutputPreview(
            displayed: displayed, full: full,
            isShortened: true, omittedCharacters: omitted
        )
    }

    private static func renderedPreview(
        _ full: String, headEnd: String.Index, tailStart: String.Index
    ) -> String {
        let omitted = full.distance(from: headEnd, to: tailStart)
        let marker = String(localized: "[… \(omitted) characters omitted …]")
        return String(full[..<headEnd]) + "\n\(marker)\n" + String(full[tailStart...])
    }

    private static func boundaryAfterLines(_ count: Int, in text: String) -> String.Index {
        guard count > 0 else { return text.startIndex }
        var lines = 1
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\n" {
                if lines == count { return index }
                lines += 1
            }
            index = text.index(after: index)
        }
        return index
    }

    private static func boundaryBeforeLastLines(_ count: Int, in text: String) -> String.Index {
        var remaining = count
        var index = text.endIndex
        while index > text.startIndex, remaining > 0 {
            index = text.index(before: index)
            if text[index] == "\n" { remaining -= 1 }
        }
        if index < text.endIndex, text[index] == "\n" {
            return text.index(after: index)
        }
        return index
    }

    private static func output(
        _ raw: String, policy: AgentToolDescriptor.Presentation.Output
    ) -> String {
        guard let value = try? AgentJSONValue.decode(Data(raw.utf8)) else { return raw }

        if case .streams = policy, let object = value.objectValue {
            let stdout = object["stdout"]?.stringValue ?? ""
            let stderr = object["stderr"]?.stringValue ?? ""
            if !stdout.isEmpty || !stderr.isEmpty {
                if stdout.isEmpty { return stderr }
                if stderr.isEmpty { return stdout }
                return String(localized: "Standard output:\n\(stdout)\nStandard error:\n\(stderr)")
            }
        }

        if case .field(let key) = policy, let text = value.objectValue?[key]?.stringValue {
            return text
        }

        if case .automatic = policy, let object = value.objectValue {
            for key in ["content", "text", "output", "body", "diff"] {
                if let text = object[key]?.stringValue { return text }
            }
        }

        return prettyJSON(value)
    }

    private static func operationName(for card: AgentToolCard) -> String {
        guard let presentation = card.descriptor.presentation else {
            return humanized(card.descriptor.qualifiedName)
        }
        switch presentation.activity {
        case .label(let label): return label
        case .argument(let key, let fallback):
            guard let value = card.invocation.call.arguments.objectValue?[key]?.stringValue else {
                return fallback
            }
            let oneLine = value.split(whereSeparator: \.isNewline).joined(separator: " ")
            return oneLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? fallback : oneLine
        case .localizedArrayCount(let key, let unit, let fallback):
            guard let count = card.invocation.call.arguments.objectValue?[key]?.arrayValue?.count,
                count > 0
            else { return fallback }
            return countDescription(count, unit: unit)
        case .arrayCount(let key, let singular, let plural, let fallback):
            guard let count = card.invocation.call.arguments.objectValue?[key]?.arrayValue?.count,
                count > 0
            else { return fallback }
            return count == 1 ? singular : "\(count) \(plural)"
        }
    }

    private static func batchClause(_ cards: [AgentToolCard]) -> String {
        guard let first = cards.first else { return "" }
        guard let presentation = first.descriptor.presentation else {
            let activity = cards.count == 1
                ? humanized(first.descriptor.qualifiedName) : toolCallCount(cards.count)
            return fallbackAction(for: first.state, activity: activity)
        }

        let activity = batchActivity(presentation.activity, cards: cards)
        if let template = presentation.messages[first.state.rawValue] {
            return replacingQuotedActivity(in: template, with: activity)
                .replacingOccurrences(of: "{activity}", with: activity)
                .replacingOccurrences(of: " on {target}", with: "")
                .replacingOccurrences(of: " to {target}", with: "")
                .replacingOccurrences(of: " with {target}", with: "")
                .replacingOccurrences(of: "{target}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fallbackAction(for: first.state, activity: activity)
    }

    private static func replacingQuotedActivity(in template: String, with activity: String) -> String {
        [
            "“{activity}”", "\"{activity}\"", "‘{activity}’", "'{activity}'",
            "«{activity}»", "‹{activity}›", "「{activity}」", "『{activity}』",
        ].reduce(template) { text, quoted in
            text.replacingOccurrences(of: quoted, with: activity)
        }
    }

    private static func batchActivity(
        _ activity: AgentToolDescriptor.Presentation.Activity,
        cards: [AgentToolCard]
    ) -> String {
        switch activity {
        case .localizedArrayCount(let key, let unit, let fallback):
            let count = cards.reduce(0) { total, card in
                total + (card.invocation.call.arguments.objectValue?[key]?.arrayValue?.count ?? 0)
            }
            guard count > 0 else { return fallback }
            return countDescription(count, unit: unit)
        case .arrayCount(let key, let singular, let plural, let fallback):
            let count = cards.reduce(0) { total, card in
                total + (card.invocation.call.arguments.objectValue?[key]?.arrayValue?.count ?? 0)
            }
            guard count > 0 else { return fallback }
            return count == 1 ? singular : "\(count) \(plural)"
        case .argument(_, let fallback):
            return cards.count == 1 ? fallback : toolCallCount(cards.count)
        case .label(let label):
            return cards.count == 1 ? label : toolCallCount(cards.count)
        }
    }

    private static func countDescription(
        _ count: Int, unit: AgentToolDescriptor.Presentation.CountedUnit
    ) -> String {
        switch unit {
        case .question: String(localized: "\(count) questions")
        }
    }

    private static func toolCallCount(_ count: Int) -> String {
        String(localized: "\(count) tool calls")
    }

    private static func fallbackAction(
        for state: AgentToolCard.State, activity: String
    ) -> String {
        switch state {
        case .proposed: "Preparing \(activity)"
        case .waitingForApproval, .waitingForUser: "Waiting to run \(activity)"
        case .reviewing: "Preparing \(activity)"
        case .running: "Running \(activity)"
        case .completed: "Ran \(activity)"
        case .denied: "Denied \(activity)"
        case .failed: "Failed \(activity)"
        case .interrupted: "Interrupted \(activity)"
        }
    }

    private static func lowercaseFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + String(text.dropFirst())
    }

    private static func tint(for state: AgentToolCard.State) -> BatchTint {
        switch state {
        case .denied, .failed: .failure
        case .reviewing, .waitingForApproval, .waitingForUser: .warning
        case .completed: .success
        case .proposed, .running, .interrupted: .secondary
        }
    }

    private static func humanized(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    private static func prettyJSON(_ value: AgentJSONValue) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: value.encodedData),
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        else { return value.encodedString }
        return String(decoding: data, as: UTF8.self)
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
