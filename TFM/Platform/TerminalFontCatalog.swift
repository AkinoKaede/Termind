import AppKit
import Observation

@MainActor @Observable
final class TerminalFontCatalog {
    static let shared = TerminalFontCatalog()
    private(set) var families: [String] = []

    private init() { refresh() }

    func refresh() {
        families = NSFontManager.shared.availableFontFamilies.filter { family in
            NSFontManager.shared.availableMembers(ofFontFamily: family)?.contains { member in
                guard let fontName = member.first as? String else { return false }
                return NSFont(name: fontName, size: 12) != nil
            } == true
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
