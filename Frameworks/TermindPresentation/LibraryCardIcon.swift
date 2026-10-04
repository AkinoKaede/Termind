import SwiftUI

public struct LibraryCardIcon: View {
    let symbol: String
    let tint: Color

    public init(symbol: String, tint: Color = .accentColor) {
        self.symbol = symbol
        self.tint = tint
    }
    #if os(macOS)
        private let size: CGFloat = 30
        private let symbolSize: CGFloat = 14
        private let cornerRadius: CGFloat = 6
    #else
        private let size: CGFloat = 36
        private let symbolSize: CGFloat = 17
        private let cornerRadius: CGFloat = 8
    #endif

    public var body: some View {
        Image(systemName: symbol).font(.system(size: symbolSize, weight: .medium)).foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: .rect(cornerRadius: cornerRadius))
            .accessibilityHidden(true)
    }
}
