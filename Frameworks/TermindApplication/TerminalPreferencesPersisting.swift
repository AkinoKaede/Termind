// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

@MainActor
public protocol TerminalPreferencesPersisting: AnyObject {
    var usesNativeTerminalThemes: Bool { get }
    func loadTerminal() throws -> TerminalPreferences
    func saveTerminal(_ value: TerminalPreferences) throws
    func loadTerminalThemes() throws -> TerminalThemeLibrary
    func saveTerminalThemes(_ value: TerminalThemeLibrary) throws
}

extension TerminalPreferencesPersisting {
    public var usesNativeTerminalThemes: Bool { false }
    public func loadTerminalThemes() throws -> TerminalThemeLibrary { .init() }
    public func saveTerminalThemes(_ value: TerminalThemeLibrary) throws {
        throw CocoaError(.featureUnsupported)
    }
}
