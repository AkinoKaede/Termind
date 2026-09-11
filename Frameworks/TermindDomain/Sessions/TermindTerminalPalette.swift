import Foundation

public nonisolated struct TermindTerminalPalette: Identifiable, Hashable, Sendable {
    public nonisolated struct RGB: Hashable, Sendable {
        public var r: Double, g: Double, b: Double

        public init(_ hex: UInt32) {
            r = Double((hex >> 16) & 0xFF) / 255
            g = Double((hex >> 8) & 0xFF) / 255
            b = Double(hex & 0xFF) / 255
        }

        public init?(hex value: String) {
            var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.hasPrefix("#") { normalized.removeFirst() }
            guard normalized.count == 6, let hex = UInt32(normalized, radix: 16) else {
                return nil
            }
            self.init(hex)
        }

        public var hex: String {
            String(
                format: "%02X%02X%02X",
                Int((r * 255).rounded()),
                Int((g * 255).rounded()),
                Int((b * 255).rounded())
            )
        }
    }

    public var id: String { name }
    public var name: String
    public var isDark: Bool

    public var background: RGB
    public var foreground: RGB
    public var cursor: RGB
    public var selection: RGB

    /// ANSI 0-7 followed by their bright variants 8-15.
    public var ansi: [RGB]

    public static let termindDark = TermindTerminalPalette(
        name: "Termind Dark",
        isDark: true,
        background: RGB(0x1E1E1E),
        foreground: RGB(0xD3D8E0),
        cursor: RGB(0x4B8BF5),
        selection: RGB(0x2A3550),
        ansi: [
            RGB(0x2A2F3A), RGB(0xE05561), RGB(0x62C073), RGB(0xD5A24C),
            RGB(0x4B8BF5), RGB(0xB07CD8), RGB(0x3FB5B5), RGB(0xABB2BF),
            RGB(0x515A6C), RGB(0xFF6E76), RGB(0x7BD98C), RGB(0xEFBD5D),
            RGB(0x6BA5FF), RGB(0xC996E8), RGB(0x56CFCF), RGB(0xE6E9EF),
        ]
    )

    public static let termindLight = TermindTerminalPalette(
        name: "Termind Light",
        isDark: false,
        background: RGB(0xFFFFFF),
        foreground: RGB(0x2B303B),
        cursor: RGB(0x2C6BD8),
        selection: RGB(0xCFDDF7),
        ansi: [
            RGB(0x3B4048), RGB(0xC4404B), RGB(0x3F8F4E), RGB(0x9C7415),
            RGB(0x2C6BD8), RGB(0x8A4FB8), RGB(0x24888A), RGB(0x6C737F),
            RGB(0x545C69), RGB(0xE05561), RGB(0x53A863), RGB(0xBB8D22),
            RGB(0x3F82EA), RGB(0xA463D0), RGB(0x2FA5A7), RGB(0x2B303B),
        ]
    )

    public static let all: [TermindTerminalPalette] = [.termindDark, .termindLight]

}
