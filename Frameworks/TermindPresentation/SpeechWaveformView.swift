import SwiftUI

/// A compact, level-driven speech waveform shared by the macOS and iOS composers.
public struct SpeechWaveformView: View {
    private let samples: [Float]
    private let reduceMotion: Bool

    public init(samples: [Float], reduceMotion: Bool) {
        self.samples = samples
        self.reduceMotion = reduceMotion
    }

    private var displayedSamples: [Float] {
        reduceMotion ? Array(repeating: 0.18, count: samples.count) : samples
    }

    public var body: some View {
        Canvas { context, size in
            let values = displayedSamples
            guard !values.isEmpty else { return }
            let step = size.width / CGFloat(max(values.count - 1, 1))

            for (index, rawValue) in values.enumerated() {
                let value = CGFloat(min(max(rawValue, 0.04), 1))
                let diameter = 2.2 + value * 3.8
                let rect = CGRect(
                    x: CGFloat(index) * step - diameter / 2,
                    y: size.height / 2 - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(.primary.opacity(0.16 + value * 0.64))
                )
            }
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: samples)
    }
}
