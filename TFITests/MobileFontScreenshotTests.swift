// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import GhosttyTerminal
import SwiftUI
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS
@testable import TermindPresentation

@Suite(.requiresKeyWindow, .serialized) @MainActor
struct MobileFontScreenshotTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["TERMIND_FONT_SCREENSHOTS"] == "1"),
        arguments: ["en", "zh-Hans"])
    func captureBundledFonts(language: String) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        var terminals: [TerminalViewState] = []
        let families =
            scene.traitCollection.userInterfaceIdiom == .pad
            ? TerminalBundledFonts.families.sorted() : ["JetBrains Mono"]
        for family in families {
            let backend = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
            let terminal = TerminalViewState(configSource: .none)
            terminal.configuration = .init(backend: .inMemory(backend), resizeThrottleMilliseconds: 0)
            let config = TermindTerminalThemeCatalog.terminalConfiguration(
                themeName: "Termind Dark", customEnabled: false, customText: "", isDark: true,
                font: .init(family: family, size: 12, sizeFollowsTheme: false))
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
        let content = VStack(spacing: 12) {
            TerminalFontOptions(
                family: .constant("JetBrains Mono"),
                families: TerminalFontCatalog.shared.families,
                builtInFamilies: TerminalFontCatalog.shared.builtInFamilies, didSelect: {}
            )
            .frame(width: 280, height: 320)
            ForEach(terminals.indices, id: \.self) { index in
                TerminalSurfaceView(context: terminals[index]).frame(height: 190)
            }
        }
        .padding(12)
        .background(Color(white: 0.12))
        .environment(\.locale, Locale(identifier: language))
        .preferredColorScheme(.dark)
        let controller = UIHostingController(rootView: content)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            for terminal in terminals { terminal.isSurfaceVisible = false }
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(1))
        for terminal in terminals {
            #expect(terminal.surfaceSize != nil)
            #expect(terminal.controller.lastConfigurationIssue == nil)
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        Attachment.record(data, named: "ios-fonts-\(language).png")
        let directory = FileManager.default.temporaryDirectory.appending(path: "termind-font-screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: "ios-fonts-\(language).png")
        try data.write(to: output)
        print("FONT_SCREENSHOT_SAVED \(output.path)")
    }
}
