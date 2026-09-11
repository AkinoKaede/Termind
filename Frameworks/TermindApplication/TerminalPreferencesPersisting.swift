import Foundation
import TermindDomain

@MainActor
public protocol TerminalPreferencesPersisting: AnyObject {
    func loadTerminal() throws -> TerminalPreferences
    func saveTerminal(_ value: TerminalPreferences) throws
}
