import GhosttyTerminal
import GhosttyTheme
import SwiftUI
import TermindDomain

/// One in-memory surface per editor. Drafts only reconfigure it; no shell or remote session is created.
@MainActor
public final class TerminalConfigurationPreviewModel: ObservableObject {
    public let terminal: TerminalViewState
    @Published public private(set) var issue: String?

    public init(
        themeName: String = TermindTerminalThemeCatalog.defaultDark.name,
        isDark: Bool = true, font: TerminalFontPreferences = .init()
    ) {
        let backend = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        terminal = TerminalViewState(configSource: .none)
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(backend), resizeThrottleMilliseconds: 0)
        terminal.setTerminalConfiguration(
            .init { builder in
                builder.withCustom("notify-on-command-finish", "never")
                builder.withWindowPaddingX(8)
                builder.withWindowPaddingY(8)
            })
        let normalColors = (0..<8).map { "\u{1B}[\(40 + $0)m  " }.joined()
        let brightColors = (0..<8).map { "\u{1B}[\(100 + $0)m  " }.joined()
        let lines = [
            "\u{1B}[36muser@server\u{1B}[0m \u{1B}[34m~\u{1B}[0m $ ls",
            "\u{1B}[1;34msrc/\u{1B}[0m  README.md  \u{1B}[32mrun.sh\u{1B}[0m",
            "",
            "\u{1B}[1mTermind\u{1B}[0m",
            normalColors + "\u{1B}[0m",
            brightColors + "\u{1B}[0m",
            "",
            "\u{1B}[36muser@server\u{1B}[0m \u{1B}[34m~\u{1B}[0m $ ",
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
            TerminalSurfaceView(context: model.terminal)
                .environment(\.colorScheme, isDark ? .dark : .light)
                .allowsHitTesting(false)
                .disabled(true)
                .accessibilityHidden(true)
                .frame(minHeight: 220)
                .clipShape(.rect(cornerRadius: 8))
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
