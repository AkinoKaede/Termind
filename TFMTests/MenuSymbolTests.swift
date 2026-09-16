import AppKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite
struct MenuSymbolTests {
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

    @Test
    @MainActor
    func menuBarBrandAssetLoadsAsATransparentTemplate() throws {
        let image = try #require(NSImage(named: "MenuBarIcon"))
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let alpha = (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).compactMap { x in bitmap.colorAt(x: x, y: y)?.alphaComponent }
        }
        #expect(alpha.contains { $0 > 0.9 })
        #expect(alpha.filter { $0 < 0.1 }.count > alpha.count / 2)
    }

}
