// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import GhosttyTerminal
import GhosttyTheme
import SwiftUI
import TermindDomain

/// One in-memory surface per editor. Drafts only reconfigure it; no shell or remote session is created.
@MainActor
public final class TerminalConfigurationPreviewModel: ObservableObject {
    public let terminal: TerminalViewState
    @Published public private(set) var issue: String?
    @Published public private(set) var palette: TerminalThemeThumbnailPalette

    public init(
        themeName: String = TermindTerminalThemeCatalog.defaultDark.name,
        isDark: Bool = true, font: TerminalFontPreferences = .init()
    ) {
        palette = TerminalThemeThumbnailPalette(
            theme: TermindTerminalThemeCatalog.resolvedTheme(named: themeName, isDark: isDark))
        let backend = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        terminal = TerminalViewState(configSource: .none)
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(backend), resizeThrottleMilliseconds: 0)
        terminal.setTerminalConfiguration(
            .init { builder in
                builder.withCustom("notify-on-command-finish", "never")
                builder.withWindowPaddingX(16)
                builder.withWindowPaddingY(16)
            })
        let lines = [
            "\u{1B}[36muser@server\u{1B}[0m \u{1B}[34m~/termind\u{1B}[0m",
            "$ git status --short",
            "\u{1B}[33m M\u{1B}[0m theme.conf",
            "\u{1B}[32m A\u{1B}[0m themes/ocean",
            "",
            "$ git diff",
            "\u{1B}[31m- background = 1e1e1e\u{1B}[0m",
            "\u{1B}[32m+ background = 152033\u{1B}[0m",
            "",
            "\u{1B}[1mAa Bb\u{1B}[0m  \u{1B}[3mAa Bb\u{1B}[0m  \u{1B}[4mAa Bb\u{1B}[0m",
            "$ ",
        ]
        backend.receive(lines.joined(separator: "\r\n"))
        update(themeName: themeName, text: "", isDark: isDark, font: font)
    }

    @discardableResult
    public func update(themeName: String, text: String, isDark: Bool, font: TerminalFontPreferences) -> Bool {
        let configuration = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: themeName, customEnabled: true, customText: text, isDark: isDark, font: font)
        let theme = TerminalTheme(light: configuration, dark: configuration)
        // Ghostty returns false for an unchanged theme. Returning to the last valid
        // draft after an error is a successful recovery, even without reconfiguration.
        let success = theme == terminal.theme || terminal.setTheme(theme)
        issue = success ? nil : terminal.controller.lastConfigurationIssue
        if success {
            palette = TerminalThemeThumbnailPalette(
                theme: TermindTerminalThemeCatalog.resolvedTheme(named: themeName, isDark: isDark), customText: text)
        }
        return success
    }
}

public struct TerminalConfigurationPreview: View {
    private let themeName: String
    private let text: String
    private let isDark: Bool
    private let font: TerminalFontPreferences
    @StateObject private var model: TerminalConfigurationPreviewModel

    public init(themeName: String, text: String, isDark: Bool, font: TerminalFontPreferences) {
        self.themeName = themeName
        self.text = text
        self.isDark = isDark
        self.font = font
        _model = StateObject(
            wrappedValue: TerminalConfigurationPreviewModel(themeName: themeName, isDark: isDark, font: font))
    }

    private var request: Request { Request(themeName: themeName, text: text, isDark: isDark, font: font) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppStrings.Settings.themePreview).font(.headline)
            VStack(spacing: 0) {
                TerminalSurfaceView(context: model.terminal)
                    .environment(\.colorScheme, isDark ? .dark : .light)
                    .allowsHitTesting(false)
                    .disabled(true)
                    .accessibilityHidden(true)
                    .frame(minHeight: 260)
                colorSamples
            }
            .background(model.palette.background.color)
            .clipShape(.rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityIdentifier("custom-theme-preview")
            if let issue = model.issue {
                Text(AppStrings.Settings.themePreviewError(issue))
                    .font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .onAppear { model.terminal.isSurfaceVisible = true }
        .onDisappear { model.terminal.isSurfaceVisible = false }
        .task(id: request) {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled else { return }
            model.update(themeName: themeName, text: text, isDark: isDark, font: font)
        }
    }

    private var colorSamples: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { textSamples }
                VStack(alignment: .leading, spacing: 12) { textSamples }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(AppStrings.Settings.themePreviewPalette)
                    .font(.caption.weight(.medium))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                    ForEach(0..<16, id: \.self) { index in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(model.palette.ansi[index].color)
                                .frame(height: 20)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(model.palette.foreground.color.opacity(0.2), lineWidth: 1)
                                }
                            Text(verbatim: "\(index)")
                                .font(.caption2.monospacedDigit())
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: "\(index): #\(model.palette.ansi[index].hex)"))
                    }
                }
            }
        }
        .foregroundStyle(model.palette.foreground.color)
        .padding(16)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var textSamples: some View {
        HStack(spacing: 8) {
            Text(AppStrings.Settings.themePreviewCursor).font(.caption)
            Text(verbatim: "A")
                .font(.body.monospaced())
                .foregroundStyle(model.palette.cursorText.color)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(model.palette.cursor.color, in: .rect(cornerRadius: 2))
        }
        Text(AppStrings.Settings.themePreviewSelection)
            .font(.body.monospaced())
            .foregroundStyle(model.palette.selectionForeground.color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(model.palette.selection.color, in: .rect(cornerRadius: 2))
    }

    private struct Request: Equatable {
        let themeName: String
        let text: String
        let isDark: Bool
        let font: TerminalFontPreferences
    }
}

/// Geometry only changes the layout, preserving editor and preview identity during resizing.
public struct TerminalConfigurationEditorLayout<Editor: View, Preview: View>: View {
    @ViewBuilder private let editor: Editor
    @ViewBuilder private let preview: Preview
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var width: CGFloat = 0

    public init(@ViewBuilder editor: () -> Editor, @ViewBuilder preview: () -> Preview) {
        self.editor = editor()
        self.preview = preview()
    }

    public var body: some View {
        let layout =
            width >= 700 && !typeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        layout {
            editor.frame(maxWidth: .infinity, minHeight: 280)
            preview.frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
    }
}
