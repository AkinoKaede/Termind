import GhosttyTerminal
import SwiftUI

struct MobileTerminalKeyboard: View {
    @ObservedObject var state: TerminalViewState
    @State private var control: TerminalPublicStickyActivation = .inactive
    @State private var alt: TerminalPublicStickyActivation = .inactive

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                key("Esc", .escape)
                key("Tab", .tab)
                modifier("Ctrl", .ctrl, activation: control)
                modifier("Alt", .alt, activation: alt)
                key("←", .arrowLeft)
                key("↓", .arrowDown)
                key("↑", .arrowUp)
                key("→", .arrowRight)
                key("Home", .home)
                key("End", .end)
                key("PgUp", .pageUp)
                key("PgDn", .pageDown)
                Button {
                    state.attachedPlatformView?.resignFirstResponder()
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                }.accessibilityLabel("Hide Keyboard")
            }
            .buttonStyle(.bordered)
            .font(.system(.callout, design: .monospaced))
            .padding(8)
        }.background(.bar)
            .onChange(of: state.isFocused, initial: true) { _, _ in
                state.attachedPlatformView?.setStickyModifierChangeHandler {
                    refreshModifiers()
                }
                refreshModifiers()
            }
            .onDisappear { state.attachedPlatformView?.setStickyModifierChangeHandler(nil) }
    }

    private func refreshModifiers() {
        control = state.attachedPlatformView?.stickyActivation(for: .ctrl) ?? .inactive
        alt = state.attachedPlatformView?.stickyActivation(for: .alt) ?? .inactive
    }

    private func modifier(
        _ title: String, _ modifier: TerminalPublicStickyModifier,
        activation: TerminalPublicStickyActivation
    ) -> some View {
        Button {
            state.attachedPlatformView?.toggleStickyModifier(modifier)
        } label: {
            Text(activation == .locked ? title + " •" : title)
        }
        .tint(activation == .inactive ? .secondary : .accentColor)
        .accessibilityValue(activation.rawValue)
    }

    private func key(_ title: String, _ key: TerminalKey) -> some View {
        Button(title) {
            _ = state.attachedPlatformView?.sendKey(TerminalKeyPress(key))
        }
    }
}
