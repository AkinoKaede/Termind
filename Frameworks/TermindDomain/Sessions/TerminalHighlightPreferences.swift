import Foundation

public nonisolated struct TerminalHighlightRule: Codable, Hashable, Sendable, Identifiable {
    public enum MatchMode: String, Codable, CaseIterable, Sendable { case text, regularExpression }
    public var id: UUID
    public var name: String
    public var pattern: String
    public var mode: MatchMode
    public var isCaseSensitive: Bool
    public var color: TagColor
    public var backgroundColor: TagColor

    public init(
        id: UUID = UUID(), name: String = "", pattern: String = "", mode: MatchMode = .text,
        isCaseSensitive: Bool = false, color: TagColor = .red, backgroundColor: TagColor = .none
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.mode = mode
        self.isCaseSensitive = isCaseSensitive
        self.color = color
        self.backgroundColor = backgroundColor
    }

    public var isBuiltIn: Bool { TerminalHighlightPreferences.builtInRules.contains { $0.id == id } }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !pattern.isEmpty
            && !pattern.contains("\0")
            && pattern.utf8.count <= 16384 && name.utf8.count <= 256
    }
}

public nonisolated struct TerminalHighlightPreferences: Codable, Hashable, Sendable {
    public static let maximumRuleCount = 64
    public static var maximumCustomRuleCount: Int { maximumRuleCount - builtInRules.count }
    public var isEnabled: Bool
    public var rules: [TerminalHighlightRule]

    public init(isEnabled: Bool = true, rules: [TerminalHighlightRule] = []) {
        self.isEnabled = isEnabled
        self.rules = rules
    }

    public var isValid: Bool {
        rules.count <= Self.maximumCustomRuleCount && rules.allSatisfy { $0.isValid && !$0.isBuiltIn }
            && Set(rules.map(\.id)).count == rules.count
    }

    /// Built-ins are fixed code definitions and never enter persistence or sync.
    public var effectiveRules: [TerminalHighlightRule] { Self.builtInRules + rules }

    public static let builtInRules: [TerminalHighlightRule] = {
        let words: [(String, String, TagColor)] = [
            ("Error", "error|err|fatal|critical|fail(?:ed|ure)?|exception", .red),
            ("Warning", "warn(?:ing)?", .yellow),
            ("OK", "ok|success(?:ful)?|succeed(?:ed)?|pass(?:ed)?", .green),
            ("Info", "info(?:rmation)?|notice", .blue),
            ("Debug", "debug|trace", .purple),
        ]
        // Include an immediate colon in the match, even inside quotes.
        // Otherwise, require balanced quoted strings after the keyword.
        let outsideQuotes =
            #"(?=(?:[^\x22\x27\\\r\n]|\\[^\r\n]|\x22(?:[^\x22\\\r\n]|\\[^\r\n])*\x22|\x27(?:[^\x27\\\r\n]|\\[^\r\n])*\x27)*$)"#
        var rules = words.enumerated().map { index, entry in
            TerminalHighlightRule(
                id: builtInID(index), name: entry.0,
                pattern: #"\b(?:"# + entry.1 + #")\b(?::|"# + outsideQuotes + ")",
                mode: .regularExpression, isCaseSensitive: false, color: entry.2)
        }
        rules.append(
            TerminalHighlightRule(
                id: builtInID(5), name: "IP address & MAC", pattern: addressPattern,
                mode: .regularExpression, isCaseSensitive: false, color: .teal))
        return rules
    }()

    private static func builtInID(_ index: Int) -> UUID {
        UUID(uuidString: "57BE4440-7BCD-4C21-923B-00000000000\(index)")!
    }

    private static let addressPattern: String = {
        // Recognize address-shaped text wherever it appears, including quoted values and URLs.
        let ipv4 = #"(?:[0-9]{1,3}\.){3}[0-9]{1,3}"#
        let hex = "[0-9A-Fa-f]{1,4}"
        let groups = "\(hex)(?::\(hex))*"
        let ipv6 = "(?:\(hex):){7}\(hex)|(?:\(groups))?::(?:\(groups))?"
        let embeddedIPv4 = "(?:\(hex):){6}\(ipv4)|(?:\(groups))?::(?:\(hex):)*\(ipv4)"
        let mac = #"(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}|(?:[0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}"#
        // Include valid CIDR lengths without accepting a shorter prefix of an invalid number.
        let ipv4Prefix = #"(?:/(?:3[0-2]|[12][0-9]|[0-9])(?![0-9]))?"#
        let ipv6Prefix = #"(?:/(?:12[0-8]|1[01][0-9]|[1-9]?[0-9])(?![0-9]))?"#
        return "(?:(?:\(embeddedIPv4)|\(ipv6))\(ipv6Prefix)|\(mac)|\(ipv4)\(ipv4Prefix))"
    }()
}
