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
    @AppStorage(SettingsKey.terminalFontThicken) private var thicken = TerminalFontPreferences.ThickenMode.followTheme

    public init() {}

    public var wrappedValue: TerminalFontPreferences {
        get {
            TerminalFontPreferences(family: family, size: size, sizeFollowsTheme: sizeFollowsTheme, thicken: thicken)
        }
        nonmutating set {
            family = newValue.family
            size = newValue.size
            sizeFollowsTheme = newValue.sizeFollowsTheme
            thicken = newValue.thicken
        }
    }

    public var projectedValue: Binding<TerminalFontPreferences> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}
