import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import TermindDomain
import Testing
import UniformTypeIdentifiers

@testable import TermindPresentation

@Suite @MainActor
struct ColorTagPickerTests {
    @Test(arguments: [ColorTagPicker.Layout.compact, .touch], [ColorScheme.light, .dark])
    func selectionChangesOnlyTheInsideOfEachSwatch(layout: ColorTagPicker.Layout, scheme: ColorScheme) throws {
        let size = layout == .compact ? 20 : 26
        for tag in TagColor.allCases {
            let plain = try swatch(tag, selected: false, layout: layout, scheme: scheme)
            let selected = try swatch(tag, selected: true, layout: layout, scheme: scheme)
            #expect(plain.width == (size + 12) * 2)
            #expect(plain.width == selected.width && plain.height == selected.height)
            let center = Double(plain.width) / 2
            var changedCenter = false
            var changedBorder = false
            let expectsLightMark = tag != .none || scheme == .dark
            for y in 0..<plain.height {
                for x in 0..<plain.width {
                    guard plain.differs(from: selected, x: x, y: y) else { continue }
                    let distance = hypot(Double(x) + 0.5 - center, Double(y) + 0.5 - center) / 2
                    #expect(distance < Double(size) / 2 - 1, "Selection must not alter the outer edge or background.")
                    let offset = (y * plain.width + x) * 4
                    let hasMarkColor = (0..<3).allSatisfy {
                        expectsLightMark ? selected.data[offset + $0] > 220 : selected.data[offset + $0] < 60
                    }
                    if distance < Double(size) / 2 - 4 && hasMarkColor {
                        changedCenter = true
                    } else if distance >= Double(size) / 2 - 4 && hasMarkColor {
                        changedBorder = true
                    }
                }
            }
            #expect(changedCenter, "A checkmark must appear in white, or adaptive primary for no color.")
            #expect(changedBorder, "An inset border must appear in white, or adaptive primary for no color.")
        }
    }

    @Test(arguments: [ColorTagPicker.Layout.compact, .touch])
    func theSamePickerUpdatesSelectionAndAppearanceWithoutResizing(layout: ColorTagPicker.Layout) throws {
        let renderer = ImageRenderer(content: Fixture(selection: .red, scheme: .light, layout: layout))
        renderer.scale = 2
        let red = try bitmap(renderer)
        renderer.content.selection = .yellow
        let yellow = try bitmap(renderer)
        #expect(red.width == yellow.width && red.height == yellow.height)
        #expect(!red.matches(yellow))
        renderer.content.selection = .none
        let none = try bitmap(renderer)
        #expect(none.width == red.width && none.height == red.height)
        #expect(!none.matches(yellow))
        renderer.content.selection = .red
        #expect(try bitmap(renderer).matches(red))
        renderer.content.scheme = .dark
        let dark = try bitmap(renderer)
        #expect(dark.width == red.width && dark.height == red.height)
        #expect(!dark.matches(red))
        renderer.content.scheme = .light
        #expect(try bitmap(renderer).matches(red))
    }

    @Test
    func exportPaletteReviewWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["TERMIND_COLOR_PICKER_SCREENSHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        #if os(macOS)
            let platform = "macos"
            let layout = ColorTagPicker.Layout.compact
        #else
            let platform = "ios"
            let layout = ColorTagPicker.Layout.touch
        #endif
        for language in ["en", "zh-Hans", "zh-Hant"] {
            for scheme in [ColorScheme.light, .dark] {
                let renderer = ImageRenderer(
                    content: VStack(alignment: .leading, spacing: 16) {
                        ForEach(TagColor.allCases) { tag in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(tag.displayName.swiftUIKey).font(.caption)
                                ColorTagPicker(selection: .constant(tag), layout: layout)
                            }
                        }
                    }
                    .frame(width: 300)
                    .padding(24)
                    .background(.background)
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.colorScheme, scheme)
                )
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                let name = "color-picker-\(platform)-\(language)-\(scheme).png"
                let url = URL(filePath: directory).appending(path: name)
                let destination = try #require(
                    CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                #expect(CGImageDestinationFinalize(destination))
                Attachment.record(try Data(contentsOf: url), named: name)
            }
        }
    }

    private func swatch(
        _ tag: TagColor, selected: Bool, layout: ColorTagPicker.Layout, scheme: ColorScheme
    ) throws -> Bitmap {
        let renderer = ImageRenderer(
            content: ColorTagPicker.Swatch(color: tag, isSelected: selected, layout: layout)
                .padding(6)
                .background(.background)
                .environment(\.colorScheme, scheme))
        renderer.scale = 2
        return try bitmap(renderer)
    }

    private func bitmap(_ renderer: ImageRenderer<some View>) throws -> Bitmap {
        let image = try #require(renderer.cgImage)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Bitmap(
            width: image.width, height: image.height,
            data: Data(bytes: try #require(context.data), count: context.bytesPerRow * context.height))
    }

    private struct Bitmap {
        let width: Int
        let height: Int
        let data: Data

        func matches(_ other: Bitmap) -> Bool {
            width == other.width && height == other.height
                // Allow one channel step of offscreen antialiasing roundoff.
                && zip(data, other.data).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
        }

        func differs(from other: Bitmap, x: Int, y: Int) -> Bool {
            let offset = (y * width + x) * 4
            return (0..<4).contains { abs(Int(data[offset + $0]) - Int(other.data[offset + $0])) > 1 }
        }
    }

    private struct Fixture: View {
        var selection: TagColor
        var scheme: ColorScheme
        let layout: ColorTagPicker.Layout

        var body: some View {
            ColorTagPicker(selection: .constant(selection), layout: layout)
                .frame(width: 300)
                .padding(8)
                .background(.background)
                .environment(\.colorScheme, scheme)
        }
    }
}
