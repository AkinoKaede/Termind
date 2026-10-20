// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import TermindPresentation
import Testing

@Suite
@MainActor
struct SpeechWaveformViewTests {
    @Test
    func waveformRespondsToLevelsAndReduceMotionMakesItStable() throws {
        let quiet = Array(repeating: Float(0.04), count: 8)
        let loud = Array(repeating: Float(1), count: 8)

        try expectPixels(render(quiet, reduceMotion: false), render(loud, reduceMotion: false), equal: false)
        try expectPixels(render(quiet, reduceMotion: true), render(loud, reduceMotion: true), equal: true)
    }

    @Test
    func updatingTheSameRendererKeepsReducedMotionStable() throws {
        let quiet = Array(repeating: Float(0.04), count: 8)
        let loud = Array(repeating: Float(1), count: 8)
        let renderer = ImageRenderer(content: WaveformFixture(samples: quiet, reduceMotion: true))
        renderer.scale = 2
        let initial = try pixels(renderer)

        renderer.content.samples = loud
        try expectPixels(initial, pixels(renderer), equal: true)

        renderer.content.reduceMotion = false
        let live = try pixels(renderer)
        try expectPixels(initial, live, equal: false)
        renderer.content.samples = quiet
        try expectPixels(live, pixels(renderer), equal: false)

        renderer.content.reduceMotion = true
        try expectPixels(initial, pixels(renderer), equal: true)
    }

    @Test
    func waveformSafelyHandlesEmptyAndOutOfRangeSamples() throws {
        #expect(try render([], reduceMotion: false).data.count == 320 * 64 * 4)
        try expectPixels(render([-1, 2], reduceMotion: false), render([0.04, 1], reduceMotion: false), equal: true)
    }

    private func render(_ samples: [Float], reduceMotion: Bool) throws -> Bitmap {
        let renderer = ImageRenderer(content: WaveformFixture(samples: samples, reduceMotion: reduceMotion))
        renderer.scale = 2
        return try pixels(renderer)
    }

    private func pixels(_ renderer: ImageRenderer<WaveformFixture>) throws -> Bitmap {
        let image = try #require(renderer.cgImage)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data)
        return Bitmap(
            data: Data(bytes: bytes, count: context.bytesPerRow * context.height),
            image: try #require(context.makeImage()))
    }

    private func expectPixels(
        _ first: Bitmap, _ second: Bitmap, equal: Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let matches =
            first.image.width == second.image.width && first.image.height == second.image.height
            // Canvas can round antialiased colors to adjacent 8-bit values on
            // macOS. A single channel step is not a change in the waveform.
            && zip(first.data, second.data).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
        if matches != equal {
            for (name, bitmap) in [("first", first), ("second", second)] {
                let data = NSMutableData()
                let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, bitmap.image, nil)
                try #require(CGImageDestinationFinalize(destination))
                Attachment.record(data as Data, named: "waveform-\(name).png")
            }
        }
        #expect(matches == equal, sourceLocation: sourceLocation)
    }

    private struct Bitmap {
        let data: Data
        let image: CGImage
    }

    private struct WaveformFixture: View {
        var samples: [Float]
        var reduceMotion: Bool

        var body: some View {
            SpeechWaveformView(samples: samples, reduceMotion: reduceMotion)
                .frame(width: 160, height: 32)
                .background(.white)
                .environment(\.colorScheme, .light)
                .transaction {
                    $0.animation = nil
                    $0.disablesAnimations = true
                }
        }
    }
}
