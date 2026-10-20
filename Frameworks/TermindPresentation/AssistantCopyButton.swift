// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

public struct AssistantCopyButton: View {
    private let text: String
    private let minimumLabelSize: CGFloat?
    private let copy: (String) -> Void
    @State private var copied = false
    @State private var copyID = UUID()

    public init(text: String, minimumLabelSize: CGFloat? = nil, copy: @escaping (String) -> Void) {
        self.text = text
        self.minimumLabelSize = minimumLabelSize
        self.copy = copy
    }

    public var body: some View {
        Button {
            copy(text)
            copied = true
            copyID = UUID()
        } label: {
            Label {
                Text(AppStrings.Common.copy)
            } icon: {
                // Keep the copy glyph's layout footprint when the narrower checkmark appears.
                Image(systemName: "doc.on.doc")
                    .hidden()
                    .overlay {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
            }
            .frame(minWidth: minimumLabelSize, minHeight: minimumLabelSize)
            .contentShape(.rect)
        }
        .accessibilityValue(Text(copied ? AppStrings.Common.copied : AppStrings.Common.copy))
        .task(id: copyID) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(1.4)) } catch { return }
            copied = false
        }
        .onChange(of: text) { _, _ in
            copied = false
            copyID = UUID()
        }
    }
}
