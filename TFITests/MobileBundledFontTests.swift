// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CoreText
import TermindDomain
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite @MainActor
struct MobileBundledFontTests {
    @Test(arguments: [
        "JetBrainsMono-Regular", "JetBrainsMono-Bold", "JetBrainsMono-Italic", "JetBrainsMono-BoldItalic",
        "SauceCodeProNerdFont-Regular", "SauceCodeProNerdFont-Bold",
        "SauceCodeProNerdFont-Italic", "SauceCodeProNerdFont-BoldItalic",
        "FiraCodeNerdFont-Regular", "FiraCodeNerdFont-Bold",
    ])
    func bundledFaceIsRegisteredFromTheAppAndContainsTerminalGlyphs(file: String) throws {
        let url = try #require(Bundle.main.url(forResource: file, withExtension: "ttf"))
        let descriptors = try #require(CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])
        let descriptor = try #require(descriptors.first)
        let postScriptName = try #require(CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String)
        let native = try #require(UIFont(name: postScriptName, size: 14))
        let font = CTFontCreateWithName(native.fontName as CFString, 14, nil)
        let source = try #require(CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)
        #expect(source.standardizedFileURL == url.standardizedFileURL)
        let family = CTFontCopyFamilyName(font) as String
        #expect(TerminalFontCatalog.shared.families.contains(family))
        #expect(TerminalFontCatalog.shared.builtInFamilies.contains(family))
        #expect(CTFontGetSymbolicTraits(font).contains(.traitBold) == file.contains("Bold"))
        #expect(CTFontGetSymbolicTraits(font).contains(.traitItalic) == file.contains("Italic"))

        // Official JetBrains Mono uses Ghostty's existing Nerd-symbol fallback.
        let characters: [UniChar] = [0x41, 0x69, 0x30] + (file.hasPrefix("JetBrainsMono-") ? [] : [0xE0B0, 0xF07B])
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        #expect(CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count))
        var advances = [CGSize](repeating: .zero, count: 3)
        _ = CTFontGetAdvancesForGlyphs(font, .horizontal, Array(glyphs.prefix(3)), &advances, 3)
        #expect(abs(advances[0].width - advances[1].width) < 0.01)
        #expect(abs(advances[0].width - advances[2].width) < 0.01)
    }

    @Test func widgetDoesNotDuplicateTerminalFonts() throws {
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        let widgets = try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "appex" }
        #expect(!widgets.isEmpty)
        for widget in widgets {
            let bundle = try #require(Bundle(url: widget))
            #expect(bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil)?.isEmpty != false)
        }
    }

    @Test(arguments: ["JetBrains Mono", "SauceCodePro Nerd Font", "FiraCode Nerd Font"])
    func selectionSurvivesAvailabilityResolutionAndReachesGhostty(family: String) {
        let font = TerminalFontPreferences(family: family).resolvingFamily(in: TerminalFontCatalog.shared.families)
        let configuration = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: "Termind Dark", customEnabled: false, customText: "", isDark: true, font: font)
        #expect(configuration.rendered.contains("font-family = \(family)"))
        let reset = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: "Termind Dark", customEnabled: false, customText: "", isDark: true)
        #expect(!reset.rendered.contains("font-family = \(family)"))
    }
}
