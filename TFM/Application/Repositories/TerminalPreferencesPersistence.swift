import Foundation
import TermindDomain

@MainActor
protocol TerminalPreferencesPersisting: AnyObject {
    func loadTerminal() throws -> TerminalPreferences
    func saveTerminal(_ value: TerminalPreferences) throws
}
