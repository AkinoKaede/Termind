// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// A full-width form row that opens a creation or configuration flow.
public struct FormNavigationAction: View {
    private let title: LocalizedStringResource
    private let value: LocalizedStringResource?
    private let action: () -> Void

    public init(title: LocalizedStringResource, value: LocalizedStringResource? = nil, action: @escaping () -> Void) {
        self.title = title
        self.value = value
        self.action = action
    }

    public var body: some View {
        if let value {
            button
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(value))
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
