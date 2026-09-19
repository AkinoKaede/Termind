import SwiftUI

// MARK: - Copy

/// A copy button that confirms itself for a moment, so a click on a glyph that
/// produces no visible change still reads as having worked.
struct CopyButton: View {
    let text: String
    var title: LocalizedStringKey? = nil

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
            if let title {
                Label(hasCopied ? "Copied" : title, systemImage: hasCopied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minHeight: 28)
                    .contentShape(.rect)
            } else {
                Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(Text(title ?? "Copy"))
        .accessibilityLabel(Text(title ?? "Copy"))
    }
}
