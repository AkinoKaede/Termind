// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

nonisolated struct ParsedShellLine: Sendable {
    var commands: [String]
    var pipelineGroups: [[String]]
    var substitutions: [String]
    var redirections: [ShellOutputRedirection]
    var isAmbiguous: Bool
}

nonisolated struct ShellOutputRedirection: Sendable {
    enum Mode: Sendable {
        case append
        case truncate
        case force
    }

    var mode: Mode
    var target: String
}

nonisolated struct ShellTokens: Sendable {
    var values: [String]
    var isAmbiguous: Bool
}

/// A deliberately bounded shell lexer. It recognizes the composition forms the
/// classifier needs without pretending to be a complete POSIX shell parser.
/// Anything it cannot balance is reported as ambiguous and therefore cannot be
/// classified read-only.
nonisolated enum ShellCommandSyntax {
    static func parse(_ input: String) -> ParsedShellLine {
        let split = splitCommands(input)
        let substitutions = commandSubstitutions(in: input)
        let redirections = outputRedirections(in: input)
        return ParsedShellLine(
            commands: split.commands,
            pipelineGroups: pipelineGroups(commands: split.commands, connectors: split.connectors),
            substitutions: substitutions.values,
            redirections: redirections.values,
            isAmbiguous: split.isAmbiguous || substitutions.isAmbiguous || redirections.isAmbiguous
        )
    }

    static func tokenize(_ input: String) -> ShellTokens {
        let characters = Array(input)
        var tokens: [String] = []
        var current = ""
        var quote: Quote = .none
        var escaped = false
        var substitutionDepth = 0
        var inBackticks = false
        var isAmbiguous = false
        var index = 0

        func finishToken() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        while index < characters.count {
            let character = characters[index]

            if escaped {
                current.append(character)
                escaped = false
                index += 1
                continue
            }
            if character == "\\" && quote != .single {
                escaped = true
                index += 1
                continue
            }

            if character == "`" && quote != .single {
                inBackticks.toggle()
                current.append(character)
                index += 1
                continue
            }

            if !inBackticks {
                if character == "'" && quote != .double {
                    quote = quote == .single ? .none : .single
                    index += 1
                    continue
                }
                if character == "\"" && quote != .single {
                    quote = quote == .double ? .none : .double
                    index += 1
                    continue
                }
            }

            if quote != .single, character == "$", characterAt(index + 1, in: characters) == "(" {
                substitutionDepth += 1
                current.append("$(")
                index += 2
                continue
            }
            if substitutionDepth > 0 {
                if character == "(" { substitutionDepth += 1 }
                if character == ")" { substitutionDepth -= 1 }
                current.append(character)
                index += 1
                continue
            }

            if character.isWhitespace && quote == .none && !inBackticks {
                finishToken()
            } else {
                current.append(character)
            }
            index += 1
        }

        if escaped || quote != .none || substitutionDepth != 0 || inBackticks {
            isAmbiguous = true
        }
        finishToken()
        return ShellTokens(values: tokens, isAmbiguous: isAmbiguous)
    }

    static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "=") else { return false }
        let name = token[token.startIndex..<equals]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    static func executableName(_ token: String) -> String {
        var value = token
        while value.first == "(" || value.first == "{" { value.removeFirst() }
        while value.last == ")" || value.last == "}" { value.removeLast() }
        return String(value.split(separator: "/").last ?? Substring(value))
    }

    private static func splitCommands(
        _ input: String
    ) -> (commands: [String], connectors: [Connector], isAmbiguous: Bool) {
        let characters = Array(input)
        var commands: [String] = []
        var connectors: [Connector] = []
        var current = ""
        var quote: Quote = .none
        var escaped = false
        var substitutionDepth = 0
        var inBackticks = false
        var index = 0

        func finishCommand() -> Bool {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                current = ""
                return false
            }
            commands.append(trimmed)
            current = ""
            return true
        }

        while index < characters.count {
            let character = characters[index]
            let next = characterAt(index + 1, in: characters)

            if escaped {
                current.append("\\")
                current.append(character)
                escaped = false
                index += 1
                continue
            }
            if character == "\\" && quote != .single {
                escaped = true
                index += 1
                continue
            }

            if character == "`" && quote != .single {
                inBackticks.toggle()
                current.append(character)
                index += 1
                continue
            }

            if !inBackticks {
                if character == "'" && quote != .double {
                    quote = quote == .single ? .none : .single
                    current.append(character)
                    index += 1
                    continue
                }
                if character == "\"" && quote != .single {
                    quote = quote == .double ? .none : .double
                    current.append(character)
                    index += 1
                    continue
                }
            }

            if quote != .single, !inBackticks, character == "$", next == "(" {
                substitutionDepth += 1
                current.append("$(")
                index += 2
                continue
            }
            if substitutionDepth > 0 {
                if character == "(" { substitutionDepth += 1 }
                if character == ")" { substitutionDepth -= 1 }
                current.append(character)
                index += 1
                continue
            }

            if quote == .none && !inBackticks {
                let beginsComment =
                    character == "#"
                    && (current.isEmpty || current.last?.isWhitespace == true)
                if beginsComment {
                    while index < characters.count, characters[index] != "\n" { index += 1 }
                    if finishCommand() { connectors.append(.boundary) }
                    if index < characters.count { index += 1 }
                    continue
                }

                if character == "\n" || character == ";" {
                    if finishCommand() { connectors.append(.boundary) }
                    index += 1
                    continue
                }
                if character == "&", next == ">" {
                    current.append(character)
                    index += 1
                    continue
                }
                if character == "&", current.last == ">" {
                    current.append(character)
                    index += 1
                    continue
                }
                if character == "&" || character == "|" {
                    if finishCommand() {
                        connectors.append(character == "|" && next != "|" ? .pipe : .boundary)
                    }
                    if next == character || (character == "|" && next == "&") { index += 2 } else { index += 1 }
                    continue
                }
            }

            current.append(character)
            index += 1
        }
        _ = finishCommand()
        if !commands.isEmpty, connectors.count >= commands.count {
            connectors.removeLast(connectors.count - commands.count + 1)
        }
        return (commands, connectors, escaped || quote != .none || substitutionDepth != 0 || inBackticks)
    }

    private static func pipelineGroups(commands: [String], connectors: [Connector]) -> [[String]] {
        guard let first = commands.first else { return [] }
        var groups: [[String]] = [[first]]
        for (index, connector) in connectors.enumerated() where commands.indices.contains(index + 1) {
            if connector == .pipe {
                groups[groups.count - 1].append(commands[index + 1])
            } else {
                groups.append([commands[index + 1]])
            }
        }
        return groups
    }

    private static func commandSubstitutions(in input: String) -> (values: [String], isAmbiguous: Bool) {
        let characters = Array(input)
        var values: [String] = []
        var quote: Quote = .none
        var escaped = false
        var index = 0
        var isAmbiguous = false

        while index < characters.count {
            let character = characters[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if character == "\\" && quote != .single {
                escaped = true
                index += 1
                continue
            }
            if character == "'" && quote != .double {
                quote = quote == .single ? .none : .single
                index += 1
                continue
            }
            if character == "\"" && quote != .single {
                quote = quote == .double ? .none : .double
                index += 1
                continue
            }
            guard quote != .single else {
                index += 1
                continue
            }

            let next = characterAt(index + 1, in: characters)
            let afterNext = characterAt(index + 2, in: characters)
            let isDollarSubstitution = character == "$" && next == "(" && afterNext != "("
            let isProcessSubstitution = (character == "<" || character == ">") && next == "("
            if isDollarSubstitution || isProcessSubstitution {
                let openIndex = index + 1
                if let match = matchingParenthesis(from: openIndex, in: characters) {
                    values.append(String(characters[(openIndex + 1)..<match]))
                    index = match + 1
                    continue
                }
                isAmbiguous = true
                break
            }

            if character == "`" {
                var content = ""
                var cursor = index + 1
                var backtickEscaped = false
                while cursor < characters.count {
                    let candidate = characters[cursor]
                    if backtickEscaped {
                        content.append(candidate)
                        backtickEscaped = false
                    } else if candidate == "\\" {
                        backtickEscaped = true
                    } else if candidate == "`" {
                        break
                    } else {
                        content.append(candidate)
                    }
                    cursor += 1
                }
                if cursor == characters.count {
                    isAmbiguous = true
                    break
                }
                values.append(content)
                index = cursor + 1
                continue
            }
            index += 1
        }
        if escaped || quote != .none { isAmbiguous = true }
        return (values, isAmbiguous)
    }

    private static func outputRedirections(in input: String) -> (values: [ShellOutputRedirection], isAmbiguous: Bool) {
        let characters = Array(input)
        var values: [ShellOutputRedirection] = []
        var quote: Quote = .none
        var escaped = false
        var index = 0
        var isAmbiguous = false

        while index < characters.count {
            let current = characters[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if current == "\\" && quote != .single {
                escaped = true
                index += 1
                continue
            }
            if current == "'" && quote != .double {
                quote = quote == .single ? .none : .single
                index += 1
                continue
            }
            if current == "\"" && quote != .single {
                quote = quote == .double ? .none : .double
                index += 1
                continue
            }
            guard quote == .none else {
                index += 1
                continue
            }

            let next = characterAt(index + 1, in: characters)
            if (current == "$" && next == "(")
                || ((current == "<" || current == ">") && next == "(")
            {
                if let match = matchingParenthesis(from: index + 1, in: characters) {
                    index = match + 1
                    continue
                }
                isAmbiguous = true
                break
            }

            var operatorIndex = index
            if current == "&", next == ">" {
                operatorIndex += 1
            } else if current == "<", next == ">" {
                operatorIndex += 1
            } else if current != ">" {
                index += 1
                continue
            }

            let following = characterAt(operatorIndex + 1, in: characters)
            if following == "&" || following == "(" {
                index = operatorIndex + 2
                continue
            }
            let mode: ShellOutputRedirection.Mode
            var targetIndex: Int
            if following == ">" {
                mode = .append
                targetIndex = operatorIndex + 2
            } else if following == "|" {
                mode = .force
                targetIndex = operatorIndex + 2
            } else {
                mode = .truncate
                targetIndex = operatorIndex + 1
            }
            while targetIndex < characters.count, characters[targetIndex].isWhitespace { targetIndex += 1 }
            let target = readWord(from: targetIndex, in: characters)
            if target.value.isEmpty {
                isAmbiguous = true
            } else {
                values.append(ShellOutputRedirection(mode: mode, target: target.value))
                targetIndex = target.endIndex
            }
            index = max(index + 1, targetIndex)
        }

        if escaped || quote != .none { isAmbiguous = true }
        return (values, isAmbiguous)
    }

    private static func matchingParenthesis(from openIndex: Int, in characters: [Character]) -> Int? {
        var depth = 1
        var quote: Quote = .none
        var escaped = false
        var index = openIndex + 1
        while index < characters.count {
            let character = characters[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if character == "\\" && quote != .single {
                escaped = true
                index += 1
                continue
            }
            if character == "'" && quote != .double {
                quote = quote == .single ? .none : .single
            } else if character == "\"" && quote != .single {
                quote = quote == .double ? .none : .double
            } else if quote == .none {
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            index += 1
        }
        return nil
    }

    private static func readWord(from start: Int, in characters: [Character]) -> (value: String, endIndex: Int) {
        var value = ""
        var quote: Quote = .none
        var escaped = false
        var index = start
        while index < characters.count {
            let character = characters[index]
            if escaped {
                value.append(character)
                escaped = false
                index += 1
                continue
            }
            if character == "\\" && quote != .single {
                escaped = true
                index += 1
                continue
            }
            if character == "'" && quote != .double {
                quote = quote == .single ? .none : .single
                index += 1
                continue
            }
            if character == "\"" && quote != .single {
                quote = quote == .double ? .none : .double
                index += 1
                continue
            }
            if quote == .none && (character.isWhitespace || ";|&".contains(character)) { break }
            value.append(character)
            index += 1
        }
        return (value, index)
    }

    private static func characterAt(_ index: Int, in characters: [Character]) -> Character? {
        guard characters.indices.contains(index) else { return nil }
        return characters[index]
    }

    private enum Quote {
        case none
        case single
        case double
    }

    private enum Connector {
        case pipe
        case boundary
    }
}
