import AppKit
import Observation

@MainActor @Observable
final class TerminalFontCatalog {
    static let shared = TerminalFontCatalog()
    private(set) var families: [String] = []

    private init() { refresh() }

    func refresh() {
        families = NSFontManager.shared.availableFontFamilies.filter { family in
            NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12)?.isFixedPitch == true
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
