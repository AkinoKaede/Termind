// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindDomain

/// Metadata rows shared by Vault editors on macOS and iOS.
public struct VaultNameField: View {
    @Binding private var text: String
    private let prompt: Text?

    public init(text: Binding<String>, prompt: Text? = nil) {
        _text = text
        self.prompt = prompt
    }

    public var body: some View {
        LabeledContent(AppStrings.Common.name.swiftUIKey) {
            TextField(AppStrings.Common.name.swiftUIKey, text: $text.singleLineText, prompt: prompt, axis: .horizontal)
                .singleLinePaste()
                .lineLimit(1)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
        }
    }
}

public struct VaultColorField: View {
    @Binding private var selection: TagColor

    public init(selection: Binding<TagColor>) { _selection = selection }

    public var body: some View {
        #if os(macOS)
            LabeledContent(AppStrings.Vault.color.swiftUIKey) {
                ColorTagPicker(selection: $selection, layout: .compact)
            }
        #else
            VStack(alignment: .leading, spacing: 8) {
                Text(AppStrings.Vault.color)
                ColorTagPicker(selection: $selection, layout: .touch)
            }
        #endif
    }
}
