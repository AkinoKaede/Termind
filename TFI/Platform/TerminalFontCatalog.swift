import Observation
import UIKit

@MainActor @Observable
final class TerminalFontCatalog {
    static let shared = TerminalFontCatalog()
    private(set) var families: [String] = []

    private init() { refresh() }

    func refresh() {
        families = UIFont.familyNames.filter { family in
            UIFont.fontNames(forFamilyName: family).contains { name in
                UIFont(name: name, size: 12) != nil
            }
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
