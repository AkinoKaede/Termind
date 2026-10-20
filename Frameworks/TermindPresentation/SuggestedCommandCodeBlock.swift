// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import MarkdownView
import SwiftUI
import TermindApplication

/// Uses the upstream code block, including its copy button and expanded sheet.
public struct SuggestedCommandCodeBlock: View {
    private let command: String
    @Environment(\.locale) private var locale

    public init(_ command: String) {
        self.command = command
    }

    public var body: some View {
        MarkdownView(Self.content(command, locale: locale), theme: Self.theme)
    }

    /// The enclosing card paints the body once; the bar keeps the upstream header tint.
    public static var theme: MarkdownTheme {
        var theme = MarkdownTheme()
        theme.colors.codeBlockBackground = .clear
        return theme
    }

    public static func content(_ command: String, locale: Locale) -> MarkdownContent {
        MarkdownContent(
            blocks: [
                .codeBlock(
                    fenceInfo: AppLocalization.resolve(AppStrings.Assistant.suggestedCommand, locale: locale),
                    content: command
                )
            ],
            rendered: [:],
            highlightMaps: [:],
            locale: locale
        )
    }
}
