import SwiftUI
import TermindPresentation

// MARK: - Copy

/// A copy button that confirms itself for a moment, so a click on a glyph that
/// produces no visible change still reads as having worked.
struct CopyButton: View {
    let text: String
    var title: LocalizedStringResource? = nil

    @State private var hasCopied = false

    var body: some View {
        Button {
            guard copyToPasteboard(text) else { return }
            hasCopied = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                hasCopied = false
            }
        } label: {
            Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .font(.body)
        .foregroundStyle(.secondary)
        .help(Text(AppStrings.Common.copy))
        .accessibilityLabel(Text(title ?? AppStrings.Common.copy))
    }
}
