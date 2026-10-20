// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindDomain

public struct MetricsGPUSection: View {
    public init(server: ServerMetric, initiallyExpanded: Bool = false) {
        self.server = server
        self.initiallyExpanded = initiallyExpanded
    }
    let server: ServerMetric
    var initiallyExpanded = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if server.gpuState == .failed, server.gpuSnapshot?.devices.isEmpty == false {
                Text("GPU metrics unavailable; showing the last sample.")
                    .font(.caption).foregroundStyle(Color.orange)
            }
            ForEach(server.gpuSnapshot?.devices ?? []) { gpu in
                MetricsGPUCard(
                    gpu: gpu, cudaVersion: server.gpuSnapshot?.cudaVersion, initiallyExpanded: initiallyExpanded)
            }
        }
    }
}

private struct MetricsGPUCard: View {
    let gpu: NvidiaGPU
    let cudaVersion: String?
    @State private var informationExpanded: Bool

    init(gpu: NvidiaGPU, cudaVersion: String?, initiallyExpanded: Bool = false) {
        self.gpu = gpu
        self.cudaVersion = cudaVersion
        _informationExpanded = State(initialValue: initiallyExpanded)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(gpu.name, systemImage: "cpu")
                .font(.caption.bold()).lineLimit(1).help(gpu.name)
            HStack(spacing: 14) {
                MetricsRing(title: "GPU", value: gpu.utilization)
                    .help(Text("GPU Utilization"))
                MetricsRing(title: "VRAM", value: gpu.memoryPercent)
                    .help(Text("VRAM Occupancy"))
                VStack(alignment: .trailing, spacing: 6) {
                    memoryRow("Used", value: gpu.memoryUsed)
                    memoryRow("VRAM Total", value: gpu.memoryTotal)
                    memoryRow("Free Memory", value: gpu.memoryFree)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            GeometryReader { geometry in
                let width = max(0, (geometry.size.width - 3 * 12) / 4)
                HStack(alignment: .top, spacing: 12) {
                    meter("GPU Memory Activity", value: gpu.memoryUtilization, color: .purple)
                        .frame(width: width).help(Text("Memory Utilization"))
                    meter("GPU Encoder", value: gpu.encoder, color: Color.green)
                        .frame(width: width).help(Text("Encoder Utilization"))
                    meter("GPU Decoder", value: gpu.decoder, color: Color.green)
                        .frame(width: width).help(Text("Decoder Utilization"))
                    meter("GPU Fan", value: gpu.fan, color: Color.orange)
                        .frame(width: width).help(Text("Fan Speed"))
                }
            }
            .frame(height: 36)
            DisclosureGroup("Device Information", isExpanded: $informationExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("UUID").foregroundStyle(.secondary)
                        Text(gpu.id).font(.system(size: 9, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Text("VBIOS").foregroundStyle(.secondary)
                        Spacer()
                        Text(gpu.vbios ?? "—").monospacedDigit()
                    }
                    HStack {
                        Text("Driver CUDA Version").foregroundStyle(.secondary)
                        Spacer()
                        Text(cudaVersion ?? "—").monospacedDigit()
                    }
                }
                .font(.caption2).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    private func memoryRow(_ title: LocalizedStringResource, value: Double?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(MetricsFormat.bytes(value, style: .memory)).font(
                .system(size: 11, weight: .semibold, design: .monospaced)
            )
            .frame(minWidth: 72, alignment: .trailing)
        }
        .lineLimit(1).minimumScaleFactor(0.7)
    }

    private func meter(_ title: LocalizedStringResource, value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            Text(MetricsFormat.percent(value)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.7)
            GeometryReader { geometry in
                Capsule().fill(.quaternary)
                    .overlay(alignment: .leading) {
                        if let value {
                            Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, value / 100)))
                        }
                    }
            }.frame(height: 3).padding(.top, 3).accessibilityHidden(true)
        }
    }
}
