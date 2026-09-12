import SwiftUI
import TermindPresentation
import Testing
#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

@Suite
@MainActor
struct SpeechWaveformViewTests {
    @Test
    func waveformRespondsToLevelsAndReduceMotionMakesItStable() throws {
        let quiet = Array(repeating: Float(0.04), count: 8)
        let loud = Array(repeating: Float(1), count: 8)

        #expect(try render(quiet, reduceMotion: false) != render(loud, reduceMotion: false))
        #expect(try render(quiet, reduceMotion: true) == render(loud, reduceMotion: true))
    }

    @Test
    func waveformSafelyHandlesEmptyAndOutOfRangeSamples() throws {
        #expect(try render([], reduceMotion: false).isEmpty == false)
        #expect(
            try render([-1, 2], reduceMotion: false)
                == render([0.04, 1], reduceMotion: false)
        )
    }

    private func render(_ samples: [Float], reduceMotion: Bool) throws -> Data {
        let renderer = ImageRenderer(
            content: SpeechWaveformView(samples: samples, reduceMotion: reduceMotion)
                .foregroundStyle(.black)
                .frame(width: 160, height: 32)
                .background(.white)
        )
        renderer.scale = 2
        #if canImport(AppKit)
            let image = try #require(renderer.nsImage)
            let bitmap = try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) })
            return try #require(bitmap.representation(using: .png, properties: [:]))
        #elseif canImport(UIKit)
            return try #require(renderer.uiImage?.pngData())
        #else
            Issue.record("Unsupported rendering platform")
            return Data()
        #endif
    }
}
