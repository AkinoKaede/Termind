import AppKit
import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite
@MainActor
struct MetricsPresentationTests {
    @Test
    func connectionAndMetricsBodiesKeepTheSameCardHeight() throws {
        let model = ServerMetricsModel(
            hosts: HostLibraryModel(), preferences: PreviewMetricsPreferences(),
            makeSampler: { SSHMetricsSampler(session: RemoteConnectionCoordinator().makeExecSession()) }
        )
        let server = ServerMetric(selection: MetricsSelection(id: UUID()), name: "Fixture")
        func height() throws -> CGFloat {
            let renderer = ImageRenderer(
                content: ServerMetricsCard(server: server, model: model, compact: true).frame(width: 350))
            return try #require(renderer.nsImage).size.height
        }
        let connecting = try height()
        server.isConnecting = false
        server.status = String(localized: "Connected — collecting metrics…")
        #expect(try height() == connecting)
        server.point = MetricsPoint(
            date: Date(), cpu: 20, memory: 50, diskRead: 0, diskWrite: 12, networkReceive: 10, networkSend: 5)
        server.status = String(localized: "Live")
        #expect(try height() == connecting)
        server.selection.enabled = false
        server.status = String(localized: "Paused")
        #expect(try height() == connecting)
    }

    @Test
    func swapRendersAsASeparatePanelBelowMemoryAndHidesAtZeroCapacity() throws {
        let withSwap = ServerMetric(selection: MetricsSelection(id: UUID()), name: "Swap Preview")
        withSwap.point = MetricsPoint(
            date: Date(), memory: 50, memoryUsed: 4_294_967_296, memoryTotal: 8_589_934_592,
            swapPercent: 75, swapUsed: 3_221_225_472, swapTotal: 4_294_967_296, swapFree: 1_073_741_824)
        let withoutSwap = ServerMetric(selection: MetricsSelection(id: UUID()), name: "No Swap Preview")
        withoutSwap.point = MetricsPoint(
            date: Date(), memory: 50, memoryUsed: 4_294_967_296, memoryTotal: 8_589_934_592,
            swapUsed: 0, swapTotal: 0, swapFree: 0)

        for language in ["en", "zh-Hans", "zh-Hant"] {
            for width in [280.0, 324.0] {
                func render(_ server: ServerMetric) throws -> NSBitmapImageRep {
                    let content = MetricsSystemPanels(server: server)
                        .frame(width: width).padding(12)
                        .background(TermindColor.windowSurface)
                        .environment(\.locale, Locale(identifier: language))
                        .environment(\.colorScheme, .light)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 2
                    let image = try #require(renderer.nsImage)
                    return try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) })
                }

                let configured = try render(withSwap)
                let hidden = try render(withoutSwap)
                #expect(configured.pixelsWide == Int((width + 24) * 2))
                #expect(configured.pixelsHigh > hidden.pixelsHigh)
                let png = try #require(configured.representation(using: .png, properties: [:]))
                try png.write(
                    to: FileManager.default.temporaryDirectory.appending(
                        path: "termind-swap-preview-\(language)-\(Int(width)).png"))
            }
        }
    }
}

private final class PreviewMetricsPreferences: MetricsConfigurationStoring {
    func load() -> [MetricsSelection] { [] }
    func save(_ selections: [MetricsSelection]) {}
}
