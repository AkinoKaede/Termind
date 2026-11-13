// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindDomain

public struct TerminalFontFields: View {
    public static let sizeRange: ClosedRange<Double> = 8...36

    @Binding private var preferences: TerminalFontPreferences
    private let families: [String]
    private let builtInFamilies: Set<String>

    public init(
        preferences: Binding<TerminalFontPreferences>, families: [String], builtInFamilies: Set<String> = []
    ) {
        _preferences = preferences
        self.families = families
        self.builtInFamilies = builtInFamilies
    }

    public var body: some View {
        TerminalFontPicker(family: $preferences.family, families: families, builtInFamilies: builtInFamilies)
        VStack(alignment: .leading, spacing: 8) {
            Picker("Font Size", selection: $preferences.sizeFollowsTheme) {
                Text(AppStrings.Settings.followTheme).tag(true)
                Text(AppStrings.Vault.custom).tag(false)
            }
            .pickerStyle(.menu)
            if !preferences.sizeFollowsTheme {
                sizeEditor
            }
        }
        Picker(AppStrings.Settings.fontThicken, selection: $preferences.thicken) {
            Text(AppStrings.Settings.followTheme).tag(TerminalFontPreferences.ThickenMode.followTheme)
            Text(AppStrings.Common.enabled).tag(TerminalFontPreferences.ThickenMode.enabled)
            Text(AppStrings.Settings.disabled).tag(TerminalFontPreferences.ThickenMode.disabled)
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder private var sizeEditor: some View {
        #if os(macOS)
            HStack {
                Slider(value: $preferences.size, in: Self.sizeRange, step: 1)
                    .labelsHidden()
                    .accessibilityLabel("Font Size")
                    .accessibilityValue(preferences.size.formatted())
                sizeLabel.frame(width: 24, alignment: .trailing)
            }
        #else
            Stepper(value: $preferences.size, in: Self.sizeRange, step: 1) {
                sizeLabel
            }
            .accessibilityLabel("Font Size")
            .accessibilityValue(preferences.size.formatted())
        #endif
    }

    private var sizeLabel: some View {
        Text(preferences.size, format: .number.precision(.fractionLength(0)))
            .monospacedDigit()
    }
}
