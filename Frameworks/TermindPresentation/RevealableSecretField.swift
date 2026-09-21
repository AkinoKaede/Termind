import SwiftUI

/// A secret entry field whose clear-text presentation is explicit and temporary.
///
/// The value remains owned by the caller. This view only controls presentation and
/// always returns to its masked state when it leaves the hierarchy or the app stops
/// being active.
public struct RevealableSecretField: View {
    private let title: LocalizedStringKey
    @Binding private var text: String
    private let prompt: Text?

    @Environment(\.scenePhase) private var scenePhase
    @State private var isRevealed = false

    public init(_ title: LocalizedStringKey, text: Binding<String>, prompt: Text? = nil) {
        self.title = title
        _text = text
        self.prompt = prompt
    }

    public var body: some View {
        HStack(spacing: 6) {
            Group {
                if isRevealed {
                    TextField(title, text: $text, prompt: prompt)
                } else {
                    SecureField(title, text: $text, prompt: prompt)
                }
            }

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRevealed ? Text("Hide Secret") : Text("Show Secret"))
        }
        .onDisappear { isRevealed = false }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { isRevealed = false }
        }
    }
}
