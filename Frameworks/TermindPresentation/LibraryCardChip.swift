import SwiftUI

public struct LibraryCardChip: View {
    private let text: Text
    private let symbol: String?
    private let tint: Color

    public init(text: String, symbol: String? = nil, tint: Color = .secondary) {
        self.text = Text(verbatim: text)
        self.symbol = symbol
        self.tint = tint
    }

    public init(title: LocalizedStringResource, symbol: String? = nil, tint: Color = .secondary) {
        text = Text(title)
        self.symbol = symbol
        self.tint = tint
    }

    #if os(macOS)
        private let font = Font.caption2
        private let horizontalPadding: CGFloat = 6
        private let verticalPadding: CGFloat = 2
    #else
        private let font = Font.caption
        private let horizontalPadding: CGFloat = 8
        private let verticalPadding: CGFloat = 4
    #endif

    public var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            text
        }
        .font(font).foregroundStyle(tint)
        .padding(.horizontal, horizontalPadding).padding(.vertical, verticalPadding)
        .background(tint.opacity(0.12), in: .capsule)
        .lineLimit(1)
        .truncationMode(.tail)
    }
}
