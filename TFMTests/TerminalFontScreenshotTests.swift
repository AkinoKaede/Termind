// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import GhosttyTerminal
import SwiftUI
import TermindDomain
import Testing

@testable import Termind
@testable import TermindPresentation

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct TerminalFontScreenshotTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["TERMIND_FONT_SCREENSHOTS"] == "1"),
        arguments: ["en", "zh-Hans"])
    func captureBundledFonts(language: String) async throws {
        var terminals: [TerminalViewState] = []
        for family in TerminalBundledFonts.families.sorted() {
            let backend = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
            let terminal = TerminalViewState(configSource: .none)
            terminal.configuration = .init(backend: .inMemory(backend), resizeThrottleMilliseconds: 0)
            let config = TermindTerminalThemeCatalog.terminalConfiguration(
                themeName: "Termind Dark", customEnabled: false, customText: "", isDark: true,
                font: .init(family: family, size: 16, sizeFollowsTheme: false))
            #expect(terminal.setTheme(.init(light: config, dark: config)))
            backend.receive(
                [
                    family,
                    "Regular  0123456789  Il1 O0",
                    "\u{1B}[1mBold     0123456789  Il1 O0\u{1B}[0m",
                    "\u{1B}[3mItalic   0123456789  Il1 O0\u{1B}[0m",
                    "\u{1B}[1;3mBoldItalic 0123456789\u{1B}[0m",
                    "-> => != === <= >=  \u{E0B0} \u{F07B}",
                    "中文混排 Chinese  日本語  한국어",
                    "|1234567890|1234567890|",
                    "|中文中文中|abcdefghij|",
                ].joined(separator: "\r\n"))
            terminal.isSurfaceVisible = true
            terminals.append(terminal)
        }
        let content = HStack(alignment: .top, spacing: 16) {
            TerminalFontOptions(
                family: .constant("JetBrains Mono"),
                families: TerminalFontCatalog.shared.families,
                builtInFamilies: TerminalFontCatalog.shared.builtInFamilies, didSelect: {}
            )
            .frame(width: 280, height: 320)
            VStack(spacing: 12) {
                ForEach(terminals.indices, id: \.self) { index in
                    TerminalSurfaceView(context: terminals[index]).frame(width: 500, height: 215)
                }
            }
        }
        .padding(16)
        .background(Color(white: 0.12))
        .environment(\.locale, Locale(identifier: language))
        .preferredColorScheme(.dark)
        let controller = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 828, height: 701),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Termind — \(language)"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        defer {
            for terminal in terminals { terminal.isSurfaceVisible = false }
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        try await Task.sleep(for: .seconds(1))
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        for terminal in terminals {
            #expect(terminal.surfaceSize != nil)
            #expect(terminal.controller.lastConfigurationIssue == nil)
        }
        // Capture this window externally with screencapture -l: cacheDisplay omits Metal.
        print("FONT_SCREENSHOT_READY \(language) \(window.windowNumber)")
        try await Task.sleep(for: .seconds(8))
    }
}
