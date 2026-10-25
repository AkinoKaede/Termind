// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI
import Testing

@testable import Termind

@Suite @MainActor
struct ManagedCardDragPresentationTests {
    @Test
    func batchPlaceholdersKeepLiftHeightsAfterGridReflowAndPaintNothing() throws {
        var frames = [
            "host": CGRect(x: 0, y: 0, width: 360, height: 150),
            "metrics": CGRect(x: 380, y: 0, width: 360, height: 280),
            "unmeasured": CGRect.zero,
        ]
        let session = ManagedCardDragSession(
            source: "servers", ids: ["host", "metrics", "unmeasured", "offscreen"],
            itemFrames: frames, fallbackSize: frames["host"]!.size)
        // Reflow must not shrink a tall Metrics slot or erase an offscreen selected item.
        frames["metrics"] = CGRect(x: 0, y: 200, width: 280, height: 170)
        let renderer = ImageRenderer(
            content: VStack(spacing: 16) {
                ForEach(session.ids, id: \.self) { id in
                    ManagedCardReorderPlaceholder(height: session.size(for: id).height)
                }
            }.frame(width: 280))
        let image = try #require(renderer.cgImage)
        #expect(image.width == 280)
        #expect(image.height == 150 + 280 + 150 + 150 + 3 * 16)
        let bitmap = NSBitmapImageRep(cgImage: image)
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: x, y: y))
                if color.alphaComponent != 0 {
                    Issue.record("An insertion slot must not paint card content, a surface, or a border")
                    return
                }
            }
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func fullSizePreviewRetainsHeaderFooterAndStandaloneCardSurface(_ scheme: ColorScheme) throws {
        let renderer = ImageRenderer(
            content: ManagedCardDragPreview(size: CGSize(width: 360, height: 240)) {
                CardTile {
                    VStack(alignment: .leading) {
                        Text("Header").font(.title).foregroundStyle(Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1))
                        Spacer()
                        Text("Footer").font(.title).foregroundStyle(Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1))
                    }
                }
            }
            .environment(\.colorScheme, scheme))
        let image = try #require(renderer.cgImage)
        #expect(image.width == 360)
        #expect(image.height == 240)
        let bitmap = NSBitmapImageRep(cgImage: image)
        var hasHeader = false
        var hasFooter = false
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if color.redComponent > 0.8 && color.blueComponent < 0.2 { hasHeader = true }
                if color.blueComponent > 0.8 && color.redComponent < 0.2 { hasFooter = true }
            }
        }
        #expect(hasHeader)
        #expect(hasFooter)
        // Native glass is not available in an offscreen preview; its fallback must fill the card.
        #expect(try #require(bitmap.colorAt(x: 180, y: 120)).alphaComponent == 1)
        #expect(try #require(bitmap.colorAt(x: 0, y: 0)).alphaComponent == 0)
    }
}
