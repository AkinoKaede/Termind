import AppKit
import SwiftUI
import TermindDomain
import TermindPresentation
import Testing

@Suite @MainActor
struct ConnectionStatusIconLayoutTests {
    @Test func statusBadgeStaysInTheBottomRightWithoutChangingTheIconFootprint() throws {
        for status: ConnectionStatus in [.disconnected, .connected, .failed("Unavailable")] {
            let renderer = ImageRenderer(
                content: ConnectionStatusIcon(status: status, style: .card(background: .clear, pulses: false)) {
                    Color.clear.frame(width: 36, height: 36)
                }
            )
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            #expect(image.width == 36)
            #expect(image.height == 36)

            let bitmap = NSBitmapImageRep(cgImage: image)
            var paintedPixels = 0
            for y in 0..<36 {
                for x in 0..<36 {
                    guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.1 else { continue }
                    paintedPixels += 1
                    #expect(x >= 28 && y >= 28)
                }
            }
            #expect(status == .disconnected ? paintedPixels == 0 : paintedPixels > 0)
        }
    }

    @Test func hostArtworkKeepsItsSizeWithAndWithoutABadge() throws {
        let distribution = try #require(DetectedDistribution(id: "ubuntu"))
        let ubuntu = TermindDomain.Host(
            name: "Ubuntu", host: "ubuntu.example",
            detectedDistribution: distribution
        )
        let unknown = TermindDomain.Host(name: "Unknown", host: "unknown.example")
        for host in [ubuntu, unknown] {
            for scheme in [ColorScheme.light, .dark] {
                for status: ConnectionStatus in [.disconnected, .connected] {
                    for style: HostSystemIcon.Style in [.standard, .desktopCard] {
                        let renderer = ImageRenderer(
                            content: HostConnectionIcon(
                                host: host, size: 36, artworkStyle: style, status: status,
                                badgeStyle: .card(background: .white, pulses: false)
                            ).environment(\.colorScheme, scheme)
                        )
                        renderer.scale = 1
                        let image = try #require(renderer.cgImage)
                        #expect(image.width == 36)
                        #expect(image.height == 36)
                    }
                }
            }
        }
    }
}
