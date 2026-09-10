import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Termind

@Suite
struct MetricsProcessTests {
    @Test
    func procStatHandlesParenthesesAndUsesRemotePageSize() throws {
        let source = """
            cpu 100 0 0 900 0 0 0 0 0 0
            cpu0 50 0 0 450 0 0 0 0 0 0
            cpu1 50 0 0 450 0 0 0 0 0 0
            pagesize 4096
            __TERMIND_PROCESSES__
            \(stat(pid: 42, name: "worker (a)", user: 10, system: 5, started: 100, pages: 25))
            """
        let result = try LinuxProcessParser.parse(source)
        #expect(result.coreCount == 2)
        let process = try #require(result.processes.first)
        #expect(process.pid == 42 && process.name == "worker (a)")
        #expect(process.memory == 102_400.0)
        #expect(process.ticks == 15 && process.started == 100)
    }

    @Test
    func processCPUIsPerCoreAndPIDReuseDoesNotInheritCounters() {
        let previous = MetricsProcessSample(
            cpu: [100, 0, 0, 900, 0, 0, 0, 0], coreCount: 2,
            processes: [
                MetricsProcessCounter(pid: 1, name: "first", ticks: 10, started: 1),
                MetricsProcessCounter(pid: 2, name: "reused", ticks: 10, started: 1),
            ])
        let current = MetricsProcessSample(
            cpu: [200, 0, 0, 900, 0, 0, 0, 0], coreCount: 2,
            processes: [
                MetricsProcessCounter(pid: 2, name: "new", ticks: 200, started: 2),
                MetricsProcessCounter(pid: 1, name: "first", ticks: 85, started: 1),
            ])
        let rows = MetricsProcess.rows(previous: previous, current: current)
        #expect(rows.first?.pid == 1)
        #expect(rows.first?.cpu == 150)
        #expect(rows.last?.cpu == nil)
        #expect(MetricsProcess.rows(previous: nil, current: current).allSatisfy { $0.cpu == nil })
    }

    @Test
    func exitedMalformedAndUnreadableProcessesDoNotFailTheSnapshot() throws {
        let source = """
            cpu 1 0 0 10 0 0 0 0
            cpu0 1 0 0 10 0 0 0 0
            pagesize unknown
            __TERMIND_PROCESSES__
            invalid
            2 (gone) R
            \(stat(pid: 42, name: "valid", user: 1, system: 0, started: 1, pages: 3))
            """
        let sample = try LinuxProcessParser.parse(source)
        #expect(sample.processes.count == 1)
        #expect(sample.processes.first?.memory == nil)
        #expect(throws: MetricsReadError.self) { try LinuxProcessParser.parse("missing procfs") }
    }

    private func stat(pid: Int, name: String, user: Int, system: Int, started: Int, pages: Int) -> String {
        var fields = Array(repeating: "0", count: 22)
        fields[0] = "R"
        fields[11] = String(user)
        fields[12] = String(system)
        fields[19] = String(started)
        fields[21] = String(pages)
        return "\(pid) (\(name)) " + fields.joined(separator: " ")
    }
}

@Suite
@MainActor
struct MetricsPresentationTests {
    @Test
    func connectionAndMetricsBodiesKeepTheSameCardHeight() throws {
        let model = ServerMetricsModel(
            hosts: HostLibraryModel(), preferences: PreviewMetricsPreferences(),
            makeSampler: { SSHMetricsSampler(session: RemoteConnectionCoordinator().makeExecSession()) },
            discover: { _, _, _ in throw MetricsReadError.output }
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
    func diskColumnsRenderAcrossTheFullAvailableWidth() throws {
        let io = MetricsDevicePoint(
            id: "8:1", read: 0, write: 0, readTotal: 438.4 * 1_073_741_824,
            writeTotal: 625.2 * 1_073_741_824, readIOPS: 0, writeIOPS: 0
        )
        for width in [246.0, 300.0] {
            let renderer = ImageRenderer(
                content: MetricsDiskTable(io: io).frame(width: width)
                    .environment(\.locale, Locale(identifier: "zh-Hans")))
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            #expect(image.size.width == CGFloat(width))
            #expect(image.size.height == 52)
            let bitmap = try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) })
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(
                to: FileManager.default.temporaryDirectory.appending(path: "termind-disk-table-\(Int(width)).png"))
        }
    }

    @Test
    func nvidiaDetailsRenderWithTwoSimulatedDevicesWithoutConnecting() throws {
        let gib = 1_073_741_824.0
        let server = ServerMetric(selection: MetricsSelection(id: UUID()), name: "GPU Preview")
        server.isConnecting = false
        server.gpuState = .available
        server.gpuSnapshot = NvidiaSnapshot(
            cudaVersion: "12.4",
            devices: [
                NvidiaGPU(
                    id: "GPU-00000000-0000-0000-0000-000000000001", name: "NVIDIA GPU 0",
                    utilization: 74, memoryUsed: 17.3 * gib, memoryTotal: 24 * gib, memoryFree: 6.7 * gib,
                    memoryUtilization: 51, encoder: 12, decoder: 0, fan: 45, vbios: "95.02.3C.00.01"
                ),
                NvidiaGPU(
                    id: "GPU-00000000-0000-0000-0000-000000000002", name: "NVIDIA GPU 1",
                    utilization: 18, memoryUsed: 4.1 * gib, memoryTotal: 24 * gib, memoryFree: 19.9 * gib,
                    memoryUtilization: 9, encoder: 0, decoder: 0, fan: nil, vbios: "95.02.3C.00.01"
                ),
            ])
        for language in ["en", "zh-Hans"] {
            for expanded in [false, true] {
                let content = MetricsGPUSection(server: server, initiallyExpanded: expanded)
                    .frame(width: 324, alignment: .leading)
                    .padding(12).background(TermindColor.windowSurface)
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.colorScheme, .light)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                var image: NSImage?
                NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { image = renderer.nsImage }
                let bitmap = try #require(image?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) })
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(bitmap.pixelsWide == 696)
                #expect(bitmap.pixelsHigh > 600)
                try png.write(
                    to: FileManager.default.temporaryDirectory.appending(
                        path: "termind-gpu-preview-\(language)\(expanded ? "-expanded" : "").png"))
            }
        }
    }

    @Test
    func compactCardsRenderInBothLanguagesAndAppearances() throws {
        let hosts = HostLibraryModel()
        let model = ServerMetricsModel(
            hosts: hosts, preferences: PreviewMetricsPreferences(),
            makeSampler: { SSHMetricsSampler(session: RemoteConnectionCoordinator().makeExecSession()) },
            discover: { _, _, _ in throw MetricsReadError.output }
        )
        let server = ServerMetric(selection: MetricsSelection(id: UUID()), name: "ElasticSearch")
        server.isConnecting = false
        server.status = ""
        server.point = MetricsPoint(
            date: Date(), cpu: 94, memory: 65, memoryUsed: 2_400_000_000, memoryTotal: 4_000_000_000,
            diskRead: 89_000_000, diskWrite: 161_000, networkReceive: 32_000, networkSend: 18_000
        )
        server.gpuState = .unavailable
        for language in ["en", "zh-Hans"] {
            for dark in [false, true] {
                let content = ServerMetricsCard(
                    server: server, model: model, compact: true, inspect: {}, openTerminal: {}
                )
                .frame(width: 350).padding(14)
                .background(TermindColor.windowSurface)
                .environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                var image: NSImage?
                NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                    image = renderer.nsImage
                }
                let bitmap = try #require(image?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) })
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(bitmap.pixelsWide >= 700)
                try png.write(
                    to: FileManager.default.temporaryDirectory.appending(
                        path: "termind-metrics-\(language)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}

private final class PreviewMetricsPreferences: MetricsConfigurationStoring {
    func load() -> [MetricsSelection] { [] }
    func save(_ selections: [MetricsSelection]) {}
}
