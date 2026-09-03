import AppKit
import Foundation
import Testing

@testable import Termind

@Suite
struct MenuSymbolTests {
    private var vocabularySource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Termind/DesignSystem/MenuSymbol.swift")
    }

    /// A misspelled SF Symbol draws nothing and reports nothing, so the menu
    /// simply loses one glyph and no one finds out. This is the only place that
    /// notices.
    @Test
    func everyGlyphResolvesToASystemSymbol() {
        for name in MenuSymbol.all {
            #expect(
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "\(name) is not an SF Symbol"
            )
        }
    }

    /// `all` is hand-written, so a new verb can be added and left out of it —
    /// which would quietly exempt the new glyph from the check above.
    @Test
    func theCheckedListCoversEveryDeclaredGlyph() throws {
        let text = try String(contentsOf: vocabularySource, encoding: .utf8)
        let declarations = text.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("static let "), trimmed.contains("= \"") else { return nil }
            let name = trimmed.dropFirst("static let ".count).prefix { $0 != " " }
            return String(name)
        }
        #expect(!declarations.isEmpty)

        let listMarker = "static let all: [String] = ["
        let listed = text.components(separatedBy: listMarker).last ?? ""
        for name in declarations {
            #expect(listed.contains(name), "MenuSymbol.\(name) is missing from `all`")
        }
    }

    @Test
    @MainActor
    func aNamedGlyphReachesTheMenuItem() {
        let withSymbol = NativeMenuEntry(title: "Delete", symbol: MenuSymbol.delete).menuItem()
        #expect(withSymbol.image != nil)

        let withoutSymbol = NativeMenuEntry(title: "Delete").menuItem()
        #expect(withoutSymbol.image == nil)

        #expect(NativeMenuEntry.separator.menuItem().isSeparatorItem)
    }
}
