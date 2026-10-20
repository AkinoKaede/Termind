// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftUI

/// Editing policy for single-line UI fields, not a transformation of stored data or secrets.
public nonisolated enum SingleLineTextInput {
    /// Preserve pasted attributes while replacing only newline runs.
    public static func normalized(_ text: NSAttributedString) -> NSAttributedString {
        let string = text.string
        guard string.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) else { return text }
        var ranges: [NSRange] = []
        var offset = 0
        var start: Int?
        for scalar in string.unicodeScalars {
            if CharacterSet.newlines.contains(scalar) {
                if start == nil { start = offset }
            } else if let runStart = start {
                ranges.append(NSRange(location: runStart, length: offset - runStart))
                start = nil
            }
            offset += scalar.utf16.count
        }
        if let start { ranges.append(NSRange(location: start, length: offset - start)) }
        let result = NSMutableAttributedString(attributedString: text)
        for range in ranges.reversed() { result.replaceCharacters(in: range, with: " ") }
        return result
    }

    public static func normalized(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) else { return text }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var isInLineBreak = false
        for scalar in text.unicodeScalars {
            if CharacterSet.newlines.contains(scalar) {
                if !isInLineBreak { result.append(" ") }
                isInLineBreak = true
            } else {
                result.unicodeScalars.append(scalar)
                isInLineBreak = false
            }
        }
        return result
    }
}

extension Binding where Value == String {
    /// Read the original value unchanged; normalize only user edits, preserving the transaction.
    public var singleLineText: Binding<String> {
        Binding(
            get: { wrappedValue },
            set: { value, transaction in
                self.transaction(transaction).wrappedValue = SingleLineTextInput.normalized(value)
            }
        )
    }
}

private struct SingleLinePasteActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
}

private struct SingleLineInputAdapterKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> AnyView)? = nil
}

extension EnvironmentValues {
    /// An app-owned adapter for native input that transforms text before native filtering.
    public var singleLineInputAdapter: (@MainActor @Sendable () -> AnyView)? {
        get { self[SingleLineInputAdapterKey.self] }
        set { self[SingleLineInputAdapterKey.self] = newValue }
    }

    /// Platforms insert normalized clipboard text at the focused field's selection.
    public var singleLinePasteAction: (@MainActor @Sendable () -> Void)? {
        get { self[SingleLinePasteActionKey.self] }
        set { self[SingleLinePasteActionKey.self] = newValue }
    }
}

private struct SingleLinePasteModifier: ViewModifier {
    @Environment(\.singleLinePasteAction) private var paste
    @Environment(\.singleLineInputAdapter) private var adapter

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
            if let paste {
                content.onPasteCommand(of: [.text]) { _ in paste() }
            } else {
                content
            }
        #else
            content.background {
                if let adapter { adapter() }
            }
        #endif
    }
}

extension View {
    /// Normalize before native single-line controls flatten each newline separately.
    public func singleLinePaste() -> some View { modifier(SingleLinePasteModifier()) }
}
