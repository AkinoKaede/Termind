import Foundation

/// One command the composer accepts in place of a message.
///
/// Deliberately not an `AppCommandDescriptor` ([AppCommandRegistry]): those are
/// navigation targets for Quick Open and the menu bar, addressed by
/// `AppCommandTarget`, and they route a *window*. These change the posture of
/// one conversation, are typed into its draft, and never leave it.
nonisolated public struct ChatSlashCommand: Identifiable, Hashable, Sendable {
    public nonisolated enum Icon: Hashable, Sendable {
        case symbol(String)
        case contextRing
    }

    /// A fixed completion offered after the name.
    ///
    /// Supplied when the menu is built rather than stored here, because the ones
    /// that exist depend on live state — `/reasoning` can only offer the efforts
    /// the resolved model supports.
    public nonisolated struct Option: Identifiable, Hashable, Sendable {
        public var id: String
        public var label: String
        public var detail: String = ""

        public init(id: String, label: String, detail: String = "") {
            self.id = id
            self.label = label
            self.detail = detail
        }
    }

    public var id: String
    /// The human-facing title in the palette. `id` remains the text accepted
    /// after `/`, so presentation can say “Plan mode” without changing `/plan`.
    public var displayName: String
    public var summary: String
    public var icon: Icon
    /// Shown after the name when the command takes free text. Empty for a
    /// command that takes none.
    public var argumentHint: String = ""

    public var name: String { "/\(id)" }

    public init(id: String, displayName: String, summary: String, icon: Icon, argumentHint: String = "") {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.icon = icon
        self.argumentHint = argumentHint
    }
}

/// What a draft beginning with `/` currently means.
nonisolated public enum ChatSlashCommandInput: Hashable, Sendable {
    /// Still naming the command; carries what follows the slash.
    case naming(String)
    /// Named, with everything after the first run of spaces.
    case argument(name: String, text: String)

    /// `nil` for a draft that is not a command.
    ///
    /// Only the **first** line is considered, and it must start at the very
    /// first character. A `/` inside prose, a path pasted into a longer message,
    /// and a code block that happens to open with a slash are all ordinary
    /// messages — the cost of getting this wrong is a message silently not sent.
    public static func parse(_ draft: String) -> ChatSlashCommandInput? {
        guard draft.hasPrefix("/") else { return nil }
        let firstLine = draft.prefix { !$0.isNewline }
        // A draft with a second line has already committed to being a message:
        // the palette closes on the newline, so anything multi-line reaching
        // here is prose that began with a slash.
        guard firstLine.count == draft.count else { return nil }

        let body = firstLine.dropFirst()
        guard let space = body.firstIndex(where: \.isWhitespace) else {
            return .naming(String(body))
        }
        let name = String(body[..<space])
        guard !name.isEmpty else { return nil }
        return .argument(
            name: name,
            text: String(body[space...].drop(while: \.isWhitespace))
        )
    }

    /// The command name typed so far, whether or not it is complete.
    public var name: String {
        switch self {
        case .naming(let partial): partial
        case .argument(let name, _): name
        }
    }

    /// Splits an argument that *names* something and then keeps going —
    /// `/skill disk-triage why is root full`.
    ///
    /// A value here rather than a `split` at the call site for the reason the
    /// rest of this file exists: what Return does with a draft should be
    /// testable without a window. `nil` when nothing was named at all.
    public var selection: (name: String, remainder: String)? {
        guard case .argument(_, let text) = self else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(trimmed.prefix { !$0.isWhitespace })
        guard !name.isEmpty else { return nil }
        return (
            name,
            String(trimmed.dropFirst(name.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

/// The rows a palette draws for one draft.
///
/// A value rather than view state so the filtering, the selection clamp, and
/// what Return does are all testable without a window.
nonisolated public struct ChatSlashCommandCompletion: Hashable, Sendable {
    public nonisolated enum Row: Identifiable, Hashable, Sendable {
        case command(ChatSlashCommand)
        case option(ChatSlashCommand, ChatSlashCommand.Option)

        public nonisolated var id: String {
            switch self {
            case .command(let command): command.id
            case .option(let command, let option): "\(command.id)/\(option.id)"
            }
        }
    }

    public var rows: [Row]

    public var isEmpty: Bool { rows.isEmpty }

    /// The keyboard selection to use when opening an option page.
    ///
    /// Matching both halves matters for model options: two providers can expose
    /// models with the same visible label, while their option IDs remain unique.
    /// A filtered or stale current value falls back to the first visible row.
    public func selectionIndex(commandID: String, optionID: String) -> Int {
        rows.firstIndex { row in
            guard case .option(let command, let option) = row else { return false }
            return command.id == commandID && option.id == optionID
        } ?? 0
    }

    /// Builds the palette for a draft.
    ///
    /// While the name is incomplete this is every command it prefixes. Once the
    /// name is complete and a space has been typed, it becomes that command's
    /// options — so `/reasoning ` offers the efforts, and a command with no
    /// options simply closes the palette and lets the argument be typed.
    public static func rows(
        draft: String,
        commands: [ChatSlashCommand],
        options: (ChatSlashCommand) -> [ChatSlashCommand.Option] = { _ in [] }
    ) -> ChatSlashCommandCompletion {
        guard let input = ChatSlashCommandInput.parse(draft) else {
            return ChatSlashCommandCompletion(rows: [])
        }
        switch input {
        case .naming(let partial):
            let matched = commands.filter {
                partial.isEmpty || $0.id.hasPrefix(partial.lowercased())
            }
            return ChatSlashCommandCompletion(rows: matched.map(Row.command))
        case .argument(let name, let text):
            guard let command = commands.first(where: { $0.id == name.lowercased() }) else {
                return ChatSlashCommandCompletion(rows: [])
            }
            let matched = options(command).filter {
                text.isEmpty || $0.id.hasPrefix(text.lowercased())
                    || $0.label.lowercased().hasPrefix(text.lowercased())
            }
            return ChatSlashCommandCompletion(
                rows: matched.map { Row.option(command, $0) }
            )
        }
    }

    /// The draft that accepting `row` should leave behind.
    ///
    /// Completing a name that takes an argument leaves a trailing space, so the
    /// palette advances to that command's options in the same keystroke.
    public static func accepted(_ row: Row, takesArgument: Bool) -> String {
        switch row {
        case .command(let command):
            takesArgument ? "\(command.name) " : command.name
        case .option(let command, let option):
            "\(command.name) \(option.id)"
        }
    }

    public init(rows: [Row]) {
        self.rows = rows
    }
}
