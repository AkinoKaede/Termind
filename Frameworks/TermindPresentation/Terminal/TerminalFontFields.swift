import SwiftUI
import TermindDomain

public struct TerminalFontFields: View {
    public static let sizeRange: ClosedRange<Double> = 8...36

    @Binding private var preferences: TerminalFontPreferences
    private let families: [String]

    public init(preferences: Binding<TerminalFontPreferences>, families: [String]) {
        _preferences = preferences
        self.families = families
    }

    public var body: some View {
        TerminalFontPicker(family: $preferences.family, families: families)
        VStack(alignment: .leading, spacing: 8) {
            Picker("Font Size", selection: $preferences.sizeFollowsTheme) {
                Text("Follow Theme").tag(true)
                Text(AppStrings.Vault.custom).tag(false)
            }
            .pickerStyle(.menu)
            if !preferences.sizeFollowsTheme {
                sizeEditor
            }
        }
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
