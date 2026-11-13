// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

public struct TerminalFontPicker: View {
    @Binding private var family: String
    private let families: [String]
    private let builtInFamilies: Set<String>
    @State private var isPresented = false

    public init(family: Binding<String>, families: [String], builtInFamilies: Set<String> = []) {
        _family = family
        self.families = families
        self.builtInFamilies = builtInFamilies
    }

    public var body: some View {
        LabeledContent("Font Family") {
            Button {
                isPresented = true
            } label: {
                HStack {
                    TerminalFontName(name: family, isAvailable: families.contains(family))
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
            }
            .accessibilityLabel("Font Family")
            .accessibilityValue(family.isEmpty ? Text("Follow Theme") : Text(verbatim: family))
            .popover(isPresented: $isPresented) {
                // Native menu pickers can discard item fonts. SwiftUI rows keep
                // each family's name as a preview on both platforms.
                TerminalFontOptions(family: $family, families: families, builtInFamilies: builtInFamilies) {
                    isPresented = false
                }
                .frame(width: 280, height: 320)
                .presentationCompactAdaptation(.popover)
            }
        }
        if !family.isEmpty && !families.contains(family) {
            Text("This font is unavailable on this device. Following the theme instead.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

}

struct TerminalFontOptions: View {
    @Binding var family: String
    let families: [String]
    let builtInFamilies: Set<String>
    let didSelect: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                option("")
                let choices = TerminalFontChoices(families: families, builtInFamilies: builtInFamilies)
                fontSection(AppStrings.Terminal.builtInFonts, families: choices.builtIn)
                fontSection(AppStrings.Terminal.systemFonts, families: choices.system)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func fontSection(_ title: LocalizedStringResource, families: [String]) -> some View {
        if !families.isEmpty {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            ForEach(families, id: \.self) { option($0) }
        }
    }

    private func option(_ name: String) -> some View {
        Button {
            family = name
            didSelect()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    TerminalFontName(name: name, isAvailable: true)
                    if builtInFamilies.contains(name), let description = TerminalBundledFonts.description(for: name) {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "checkmark").opacity(family == name ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(family == name ? [.isSelected] : [])
    }
}

private struct TerminalFontName: View {
    let name: String
    let isAvailable: Bool

    var body: some View {
        if name.isEmpty {
            Text("Follow Theme")
        } else {
            Text(verbatim: name)
                .font(isAvailable ? .custom(name, size: 14, relativeTo: .body) : .body)
        }
    }
}
