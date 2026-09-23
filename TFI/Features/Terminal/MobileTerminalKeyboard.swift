import GhosttyTerminal
import SwiftUI
import TermindPresentation

struct MobileTerminalKeyboard: View {
    static let barHeight: CGFloat = 44

    @ObservedObject var state: TerminalViewState
    let paste: () -> Void
    @State private var control: TerminalPublicStickyActivation = .inactive
    @State private var alt: TerminalPublicStickyActivation = .inactive
    @State private var shift = MobileTerminalShiftState()

    init(
        state: TerminalViewState, initialShift: MobileTerminalShiftState = MobileTerminalShiftState(),
        paste: @escaping () -> Void
    ) {
        self.state = state
        self.paste = paste
        _shift = State(initialValue: initialShift)
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    key(AppStrings.Terminal.escape, systemImage: "escape", .escape)
                    key(AppStrings.Terminal.tab, systemImage: "arrow.right.to.line", .tab)
                    modifier(AppStrings.Terminal.control, systemImage: "control", .ctrl, activation: control)
                    modifier(AppStrings.Terminal.option, systemImage: "option", .alt, activation: alt)
                    shiftModifier
                    key(AppStrings.Terminal.leftArrow, systemImage: "arrowtriangle.left.fill", .arrowLeft)
                    key(AppStrings.Terminal.downArrow, systemImage: "arrowtriangle.down.fill", .arrowDown)
                    key(AppStrings.Terminal.upArrow, systemImage: "arrowtriangle.up.fill", .arrowUp)
                    key(AppStrings.Terminal.rightArrow, systemImage: "arrowtriangle.right.fill", .arrowRight)
                    key(AppStrings.Terminal.home, systemImage: "arrow.up.to.line.compact", .home)
                    key(AppStrings.Terminal.end, systemImage: "arrow.down.to.line.compact", .end)
                    key(AppStrings.Terminal.pageUp, systemImage: "arrowtriangle.up.square", .pageUp)
                    key(AppStrings.Terminal.pageDown, systemImage: "arrowtriangle.down.square", .pageDown)
                    ForEach(MobileTerminalControlShortcut.allCases) { shortcut in
                        controlShortcut(shortcut)
                    }
                }
                .padding(.leading, 8)
            }
            .frame(maxWidth: .infinity)

            Divider().padding(.vertical, 8)
            HStack(spacing: 0) {
                pasteButton
                keyboardToggle
            }
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .font(.system(.callout, design: .monospaced))
        .frame(height: Self.barHeight)
        .background(.bar)
        .onChange(of: state.isFocused, initial: true) { _, _ in
            state.attachedPlatformView?.setStickyModifierChangeHandler {
                refreshModifiers()
            }
            refreshModifiers()
        }
        .onDisappear { state.attachedPlatformView?.setStickyModifierChangeHandler(nil) }
    }

    private var shiftModifier: some View {
        Button {
            shift.toggle()
        } label: {
            modifierLabel(AppStrings.Terminal.shift, systemImage: "shift", activation: shift.activation)
        }
        .accessibilityValue(accessibilityValue(for: shift.activation))
        .accessibilityAddTraits(shift.activation == .inactive ? [] : .isSelected)
    }

    private var pasteButton: some View {
        Button(action: paste) {
            Label(AppStrings.Common.paste.swiftUIKey, systemImage: "doc.on.clipboard")
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
    }

    private var keyboardToggle: some View {
        Button {
            if state.isFocused {
                state.attachedPlatformView?.resignFirstResponder()
            } else {
                state.requestFocus()
            }
        } label: {
            Label(
                state.isFocused
                    ? AppStrings.Terminal.hideKeyboard.swiftUIKey : AppStrings.Terminal.showKeyboard.swiftUIKey,
                systemImage: state.isFocused ? "keyboard.chevron.compact.down" : "keyboard"
            )
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
        }
    }

    private func refreshModifiers() {
        control = state.attachedPlatformView?.stickyActivation(for: .ctrl) ?? .inactive
        alt = state.attachedPlatformView?.stickyActivation(for: .alt) ?? .inactive
    }

    private func modifier(
        _ title: LocalizedStringResource, systemImage: String, _ modifier: TerminalPublicStickyModifier,
        activation: TerminalPublicStickyActivation
    ) -> some View {
        Button {
            state.attachedPlatformView?.toggleStickyModifier(modifier)
        } label: {
            modifierLabel(title, systemImage: systemImage, activation: activation)
        }
        .accessibilityValue(accessibilityValue(for: activation))
        .accessibilityAddTraits(activation == .inactive ? [] : .isSelected)
    }

    private func modifierLabel(
        _ title: LocalizedStringResource, systemImage: String, activation: TerminalPublicStickyActivation
    ) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .foregroundStyle(
                activation == .inactive
                    ? AnyShapeStyle(.secondary)
                    : AnyShapeStyle(Color.accentColor)
            )
            .frame(width: 44, height: 44)
            .background(
                activation == .inactive ? Color.clear : Color.accentColor.opacity(0.18),
                in: .rect(cornerRadius: 8)
            )
            .contentShape(.rect)
            .overlay(alignment: .topTrailing) {
                if activation == .locked {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityHidden(true)
                }
            }
    }

    private func accessibilityValue(for activation: TerminalPublicStickyActivation) -> Text {
        switch activation {
        case .inactive: Text(AppStrings.Terminal.inactive)
        case .armed: Text(AppStrings.Terminal.armed)
        case .locked: Text(AppStrings.Terminal.locked)
        }
    }

    private func key(_ title: LocalizedStringResource, systemImage: String, _ key: TerminalKey) -> some View {
        Button {
            var shiftState = shift
            let modifiers = shiftState.consumeForNextKey()
            shift = shiftState
            _ = state.attachedPlatformView?.sendKey(TerminalKeyPress(key, modifiers: modifiers))
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
    }

    private func controlShortcut(_ shortcut: MobileTerminalControlShortcut) -> some View {
        Button {
            _ = state.attachedPlatformView?.sendKey(shortcut.keyPress)
        } label: {
            Text(verbatim: shortcut.label)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel(Text(AppStrings.Terminal.control) + Text(verbatim: " \(shortcut.letter)"))
    }
}

nonisolated enum MobileTerminalControlShortcut: String, CaseIterable, Identifiable {
    case c = "C"
    case i = "I"
    case s = "S"
    case z = "Z"

    var id: Self { self }
    var letter: String { rawValue }
    var label: String { "^\(letter)" }

    var keyPress: TerminalKeyPress {
        TerminalKeyPress(key, modifiers: .ctrl)
    }

    private var key: TerminalKey {
        switch self {
        case .c: .c
        case .i: .i
        case .s: .s
        case .z: .z
        }
    }
}

nonisolated struct MobileTerminalShiftState: Equatable {
    private(set) var activation: TerminalPublicStickyActivation = .inactive
    private var lastTap = Date.distantPast
    private let doubleTapInterval: TimeInterval = 0.3

    init(activation: TerminalPublicStickyActivation = .inactive) {
        self.activation = activation
    }

    mutating func toggle(at date: Date = .now) {
        switch activation {
        case .inactive:
            activation = .armed
        case .armed:
            activation = date.timeIntervalSince(lastTap) < doubleTapInterval ? .locked : .inactive
        case .locked:
            activation = .inactive
        }
        lastTap = date
    }

    mutating func consumeForNextKey() -> TerminalInputModifiers {
        guard activation != .inactive else { return [] }
        if activation == .armed { activation = .inactive }
        return .shift
    }
}
