import AppKit
import Foundation
import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain
import Testing

@testable import Termind
@testable import TermindPresentation

@Suite @MainActor
struct TerminalKeywordHighlightingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func settingsAndEditorFitTheirOffscreenWindows(_ language: String) async throws {
        let model = TerminalHighlightSettingsModel()
        var backgroundRule = TermindDomain.TerminalHighlightPreferences.builtInRules[1]
        backgroundRule.id = UUID()
        backgroundRule.color = .none
        backgroundRule.backgroundColor = .yellow
        #expect(model.upsert(backgroundRule))
        let views: [(String, AnyView)] = [
            ("settings", AnyView(SettingsFormPage { TerminalHighlightSettingsSection(model: model) { _ in } })),
            ("editor", AnyView(TerminalHighlightRuleEditorPage(rule: backgroundRule, model: model, deleted: {}))),
            ("new-editor", AnyView(TerminalHighlightRuleEditorPage(rule: .init(), model: model, deleted: {}))),
            (
                "invalid-editor",
                AnyView(
                    TerminalHighlightRuleEditorPage(
                        rule: .init(name: "Invalid", pattern: "[", mode: .regularExpression), model: model, deleted: {})
                )
            ),
        ]
        for (name, view) in views {
            let controller = NSHostingController(rootView: view.environment(\.locale, Locale(identifier: language)))
            controller.sizingOptions = []
            let window = NSWindow(
                contentRect: .init(x: 0, y: 0, width: 600, height: 760),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            defer {
                window.contentViewController = nil
                window.close()
            }
            controller.view.frame = .init(x: 0, y: 0, width: 600, height: 760)
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            controller.view.layoutSubtreeIfNeeded()
            #expect(controller.view.bounds.width == 600)
            #expect(!window.isVisible)
            let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            Attachment.record(data, named: "keyword-\(name)-\(language).png")
            let directory = FileManager.default.temporaryDirectory.appending(path: "termind-keyword-ui")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appending(path: "keyword-\(name)-\(language).png"))
        }
    }

    @Test func builtInRulesCompileUsingTheActualTerminalEngine() {
        for rule in TerminalHighlightPreferences.builtInRules {
            #expect(TerminalKeywordHighlighting.validationIssue(rule) == nil, "\(rule.name)")
        }
    }

    @Test func logKeywordsMatchAllCasesAndKeepWordBoundaries() throws {
        for rule in TerminalHighlightPreferences.builtInRules.prefix(5) {
            #expect(!rule.isCaseSensitive)
            let expression = try NSRegularExpression(pattern: rule.pattern, options: .caseInsensitive)
            for keyword in [rule.name.lowercased(), rule.name.uppercased(), rule.name] {
                let text = "\(keyword):"
                let range = NSRange(text.startIndex..., in: text)
                #expect(expression.firstMatch(in: text, range: range)?.range == range)
            }
        }
        let warning = TerminalHighlightPreferences.builtInRules[1]
        let expression = try NSRegularExpression(pattern: warning.pattern, options: .caseInsensitive)
        let text = "Warn Warning WARN WARNING wArN warn warning prewarning WARNINGS"
        let words = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            (text as NSString).substring(with: $0.range)
        }
        #expect(words == ["Warn", "Warning", "WARN", "WARNING", "wArN", "warn", "warning"])
        let error = try NSRegularExpression(
            pattern: TerminalHighlightPreferences.builtInRules[0].pattern, options: .caseInsensitive)
        let messages = #"msg="xxx error" Error: ERROR msg="Error" error error: errors preerror"#
        let matches = error.matches(in: messages, range: NSRange(messages.startIndex..., in: messages))
        #expect(
            matches.map { (messages as NSString).substring(with: $0.range) }
                == ["Error:", "ERROR", "error", "error:"])
    }

    @Test func quotedLogKeywordsRequireAnImmediateColon() throws {
        for rule in TerminalHighlightPreferences.builtInRules.prefix(5) {
            let expression = try NSRegularExpression(pattern: rule.pattern, options: .caseInsensitive)
            let keywords = rule.name == "Warning" ? ["warn", "warning"] : [rule.name.lowercased()]
            for keyword in keywords {
                for (text, expected) in [
                    ("\(keyword) before \"ordinary text\"", [keyword]),
                    ("\(keyword): detail", [keyword + ":"]),
                    ("\(keyword):detail", [keyword + ":"]),
                    ("\(keyword) : detail", [keyword]),
                    ("pre\(keyword):", []),
                    ("msg=\"xxx \(keyword)\"", []),
                    ("msg=\"\(keyword): detail\"", [keyword + ":"]),
                    ("msg=\"\(keyword) : detail\"", []),
                    ("msg='xxx \(keyword)'", []),
                    ("msg='\(keyword): detail'", [keyword + ":"]),
                    ("msg=\"don't \(keyword)\" \(keyword)", [keyword]),
                    ("msg=\"say \\\"\(keyword)\\\" now\" \(keyword)", [keyword]),
                    ("\"\(keyword): \(keyword)\" \(keyword) '\(keyword)'", [keyword + ":", keyword]),
                ] {
                    let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    #expect(
                        matches.map { (text as NSString).substring(with: $0.range) } == expected,
                        "\(rule.name): \(text)")
                }
            }
        }
    }

    @Test func plainTextTreatsUnbalancedRegexSyntaxAsLiteralAndChangingModeClearsTheIssue() {
        for pattern in ["(", ")", "[", "{", "*", "\\", "(?i:"] {
            let rule = TerminalHighlightRule(name: "Literal", pattern: pattern, mode: .text)
            #expect(TerminalKeywordHighlighting.validationIssue(rule) == nil, "\(pattern)")
        }
        var rule = TerminalHighlightRule(name: "Switch mode", pattern: "(", mode: .regularExpression)
        #expect(TerminalKeywordHighlighting.validationIssue(rule) != nil)
        rule.mode = .text
        #expect(TerminalKeywordHighlighting.validationIssue(rule) == nil)
        rule.mode = .regularExpression
        for _ in 0..<3 { #expect(TerminalKeywordHighlighting.validationIssue(rule) != nil) }
    }

    @Test func addressesMatchInsideQuotesURLsAndAdjacentText() throws {
        let expression = try NSRegularExpression(pattern: TerminalHighlightPreferences.builtInRules[5].pattern)
        for address in [
            "192.168.1.20", "::1", "::", "2001:db8::1", "::ffff:192.0.2.1", "aa:bb:cc:dd:ee:ff", "aa-bb-cc-dd-ee-ff",
        ] {
            let range = NSRange(address.startIndex..., in: address)
            #expect(expression.firstMatch(in: address, range: range)?.range == range, "\(address)")
        }
        for (text, expected) in [
            (#"msg="192.168.1.20""#, "192.168.1.20"),
            ("https://192.168.1.20:443/path", "192.168.1.20"),
            ("prefix192.168.1.20suffix", "192.168.1.20"),
            ("[2001:db8::1]:443", "2001:db8::1"),
            (#"mac="aa:bb:cc:dd:ee:ff""#, "aa:bb:cc:dd:ee:ff"),
            ("prefixAA-BB-CC-DD-EE-FFsuffix", "AA-BB-CC-DD-EE-FF"),
            ("999.168.1.20", "999.168.1.20"),
        ] {
            let match = try #require(expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
            #expect((text as NSString).substring(with: match.range) == expected)
        }
        // Ghostty's file parser has a 4096-byte line buffer, including the config key and colors.
        let runtime = TerminalKeywordHighlighting.runtimeRule(
            TerminalHighlightPreferences.builtInRules[5], environment: EnvironmentValues())
        let state = TerminalViewState(configSource: .none)
        #expect(state.setKeywordHighlightRules([runtime]))
        #expect(state.renderedConfig.split(separator: "\n").allSatisfy { $0.utf8.count < 4094 })

    }

    @Test func literalTextIsEscapedAndConfigurationUpdatesPreserveOtherSettings() {
        let state = TerminalViewState(configSource: .none)
        let rule = TerminalKeywordHighlightRule(pattern: #"[error].*\E"#, foregroundRGB: 0xFF0000)
        #expect(rule.validationIssue() == nil)
        #expect(state.setKeywordHighlightRules([rule]))
        state.setTerminalConfiguration(.init { $0.withFontSize(19) })
        #expect(state.keywordHighlightRules == [rule])
        #expect(state.renderedConfig.contains("font-size = 19"))
        #expect(state.renderedConfig.contains("keyword-highlight = FF0000,-:"))
        let invalid = TerminalKeywordHighlightRule(pattern: "[", mode: .regularExpression, foregroundRGB: 0)
        #expect(invalid.validationIssue() != nil)
        #expect(!state.setKeywordHighlightRules([invalid]))
        #expect(state.keywordHighlightRules == [rule])
        #expect(state.setKeywordHighlightRules([]))
        #expect(!state.renderedConfig.contains("FF0000,-:"))
    }

    @Test func noColorPreservesForegroundAndBackgroundCanBeSelectedIndependently() {
        let environment = EnvironmentValues()
        let rule = TerminalHighlightRule(name: "Background", pattern: "Warn", color: .none, backgroundColor: .yellow)
        let runtime = TerminalKeywordHighlighting.runtimeRule(rule, environment: environment)
        #expect(runtime.foregroundRGB == nil)
        #expect(runtime.backgroundRGB != nil)
        #expect(
            TerminalKeywordHighlighting.runtimeRule(
                .init(name: "None", pattern: "x", color: .none), environment: environment
            ).backgroundRGB == nil)
    }

    @Test func runtimeColorsResolveFromExistingPaletteForBothAppearances() {
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            for rule in TerminalHighlightPreferences.builtInRules {
                let runtime = TerminalKeywordHighlighting.runtimeRule(rule, environment: environment)
                let color = rule.color.color!.resolve(in: environment)
                let components = [color.red, color.green, color.blue].map { UInt32(($0 * 255).rounded()) }
                #expect(runtime.foregroundRGB == components[0] << 16 | components[1] << 8 | components[2])
            }
        }
    }
}
