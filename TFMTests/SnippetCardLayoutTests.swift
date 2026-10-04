import AppKit
import SwiftUI
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite @MainActor
struct SnippetCardLayoutTests {
    @Test func snippetIconsMatchOtherDesktopCards() {
        let snippet = NSHostingView(rootView: LibraryCardIcon(symbol: "curlybraces"))
        let standard = NSHostingView(rootView: CardIcon(symbol: "curlybraces"))
        #expect(snippet.fittingSize == standard.fittingSize)
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func snippetCardsUseTheStandardDesktopHeight(locale: String) {
        for width in [Metrics.Card.min, Metrics.Card.max] {
            for script in ["uptime", "sudo systemctl restart nginx", "rm -rf /"] {
                let content = SnippetCardContent(
                    snippet: Snippet(title: "Production database maintenance", body: script),
                    validTargetCount: 12, packagePath: "Operations / Production",
                    modifiedAt: Date().addingTimeInterval(-3600))
                let tile = CardTile(extendSelection: nil) { content }
                let host = NSHostingView(
                    rootView: tile.frame(width: width).environment(\.locale, Locale(identifier: locale)))
                #expect(abs(host.fittingSize.height - Metrics.Card.minHeight) <= 1)
            }
        }
    }
}
