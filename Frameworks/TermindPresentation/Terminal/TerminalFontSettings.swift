// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindDomain

/// Shares device-local typography between Settings and every mounted terminal.
@propertyWrapper
public struct TerminalFontSettings: DynamicProperty {
    @AppStorage(SettingsKey.terminalFontFamily) private var family = ""
    @AppStorage(SettingsKey.terminalFontSize) private var size = 12.0
    @AppStorage(SettingsKey.terminalFontFollowTheme) private var sizeFollowsTheme = true

    public init() {}

    public var wrappedValue: TerminalFontPreferences {
        get { TerminalFontPreferences(family: family, size: size, sizeFollowsTheme: sizeFollowsTheme) }
        nonmutating set {
            family = newValue.family
            size = newValue.size
            sizeFollowsTheme = newValue.sizeFollowsTheme
        }
    }

    public var projectedValue: Binding<TerminalFontPreferences> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}
