// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// A single button makes the value, caption, whitespace and copy glyph one accessible action.
struct TailscaleCopyField: View {
    let label: LocalizedStringResource
    let value: String
    let copy: (String) -> Void
    @State private var copied = false
    @State private var copyID = UUID()

    var body: some View {
        if !value.isEmpty {
            Button {
                copy(value)
                copied = true
                copyID = UUID()
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: value)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(.secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(label) + Text(verbatim: ": " + value))
            .accessibilityValue(Text(copied ? AppStrings.Common.copied : AppStrings.Common.copy))
            .accessibilityHint(Text(AppStrings.Tailscale.copyValue))
            .accessibilityIdentifier("tailscale.copy.\(value)")
            .task(id: copyID) {
                guard copied else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                copied = false
            }
            .onChange(of: value) { _, _ in
                copied = false
                copyID = UUID()
            }
        }
    }
}
