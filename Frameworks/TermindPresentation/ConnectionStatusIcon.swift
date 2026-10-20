// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindDomain

extension ConnectionStatus {
    public var tint: Color {
        switch self {
        case .disconnected: .secondary
        case .connecting, .reconnecting: .orange
        case .connected: .green
        case .failed: .red
        }
    }

    public var label: String {
        switch self {
        case .disconnected: String(localized: AppStrings.Connections.notConnected)
        case .connecting: String(localized: AppStrings.Connections.connecting)
        case .connected: String(localized: AppStrings.Connections.connected)
        case .reconnecting: String(localized: AppStrings.Connections.reconnecting)
        case .failed(let message): message
        }
    }

    public func showsIconBadge(hasUnread: Bool = false) -> Bool {
        self != .disconnected || hasUnread
    }

    /// Connection progress takes precedence over unread output.
    public func indicatorTint(hasUnread: Bool = false) -> Color {
        hasUnread && !isBusy ? .accentColor : tint
    }
}

/// Also usable on its own, where a disconnected connection still needs a gray dot.
public struct ConnectionStatusDot: View {
    private let status: ConnectionStatus
    private let hasUnread: Bool
    private let size: CGFloat
    private let pulses: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    public init(status: ConnectionStatus, hasUnread: Bool = false, size: CGFloat = 7, pulses: Bool = true) {
        self.status = status
        self.hasUnread = hasUnread
        self.size = size
        self.pulses = pulses
    }

    public var body: some View {
        let animatesPulse = isPulsing && pulses && !reduceMotion
        Circle()
            .fill(status.indicatorTint(hasUnread: hasUnread))
            .frame(width: size, height: size)
            .opacity(animatesPulse ? 0.3 : 1)
            // Remove the repeating animation when settled, rather than animating back with it.
            .animation(
                animatesPulse ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil,
                value: animatesPulse
            )
            .onAppear { isPulsing = status.isBusy }
            .onChange(of: status.isBusy) { _, busy in isPulsing = busy }
            .accessibilityLabel(Text(status.label))
            .allowsHitTesting(false)
    }
}

/// Platform surfaces supply their native background colors without importing UI frameworks here.
public struct ConnectionBadgeStyle {
    let size: CGFloat
    let padding: CGFloat
    let background: Color
    let border: Color
    let borderWidth: CGFloat
    let offset: CGSize
    let pulses: Bool

    public static func card(background: Color, pulses: Bool = true) -> Self {
        Self(
            size: 8, padding: 0, background: .clear, border: background, borderWidth: 1.5,
            offset: .zero, pulses: pulses
        )
    }

    public static var sidebar: Self {
        Self(
            size: 6, padding: 0, background: .clear, border: .clear, borderWidth: 0,
            offset: CGSize(width: 3, height: 3), pulses: true
        )
    }

    public static func welcome(background: Color, border: Color) -> Self {
        Self(
            size: 7, padding: 2, background: background, border: border, borderWidth: 0.5,
            offset: CGSize(width: 2, height: 2), pulses: true
        )
    }
}

/// A status badge on any icon, without changing the icon's layout footprint.
public struct ConnectionStatusIcon<Icon: View>: View {
    private let status: ConnectionStatus?
    private let hasUnread: Bool
    private let style: ConnectionBadgeStyle
    private let icon: Icon

    public init(
        status: ConnectionStatus? = nil,
        hasUnread: Bool = false,
        style: ConnectionBadgeStyle,
        @ViewBuilder icon: () -> Icon
    ) {
        self.status = status
        self.hasUnread = hasUnread
        self.style = style
        self.icon = icon()
    }

    public var body: some View {
        icon.overlay(alignment: .bottomTrailing) {
            if let status, status.showsIconBadge(hasUnread: hasUnread) {
                ConnectionStatusDot(status: status, hasUnread: hasUnread, size: style.size, pulses: style.pulses)
                    .padding(style.padding)
                    .background(style.background, in: .circle)
                    .overlay { Circle().strokeBorder(style.border, lineWidth: style.borderWidth) }
                    .offset(style.offset)
            }
        }
    }
}
