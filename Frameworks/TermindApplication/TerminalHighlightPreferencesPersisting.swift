import TermindDomain

@MainActor
public protocol TerminalHighlightPreferencesPersisting: AnyObject {
    func loadTerminalHighlightPreferences() throws -> TerminalHighlightPreferences
    func saveTerminalHighlightPreferences(_ value: TerminalHighlightPreferences) throws
}
