import SwiftUI
import TermindApplication
import TermindDomain

/// Independently scrollable system panels; the process table owns its own viewport.
public struct MetricsSystemPanels: View {
    public init(server: ServerMetric) { self.server = server }
    let server: ServerMetric
    private var point: MetricsPoint? { server.point }
    @State private var virtualInterfacesExpanded = false

    public var body: some View {
        VStack(spacing: 12) {
            panel { MetricsCPUContent(point: point) }
            panel {
                HStack {
                    MetricsFigure("Free Memory", value: MetricsFormat.bytes(point?.memoryFree))
                    MetricsFigure("Used", value: MetricsFormat.bytes(point?.memoryUsed))
                    MetricsFigure("Page Cache", value: MetricsFormat.bytes(point?.memoryCached))
                    MetricsRing(title: AppStrings.Metrics.memory, value: point?.memory)
                }
            }
            if let swapTotal = point?.swapTotal, swapTotal > 0 {
                panel {
                    HStack {
                        MetricsFigure("Free Memory", value: MetricsFormat.bytes(point?.swapFree))
                        MetricsFigure("Used", value: MetricsFormat.bytes(point?.swapUsed))
                        MetricsFigure("Total", value: MetricsFormat.bytes(point?.swapTotal))
                        MetricsRing(title: "Swap", value: point?.swapPercent)
                    }
                }
            }
            if server.gpuSnapshot?.devices.isEmpty == false {
                MetricsGPUSection(server: server)
            }
            networkPanel
            if server.filesystemsFailed {
                Text("Filesystem metrics unavailable").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(server.filesystems) { filesystem in
                filesystemPanel(filesystem)
            }
        }
    }

    private var hardwareInterfaces: [MetricsDevicePoint] {
        (point?.networkDevices ?? []).filter { $0.kind != .virtual }
    }
    private var virtualInterfaces: [MetricsDevicePoint] { (point?.networkDevices ?? []).filter { $0.kind == .virtual } }

    private var networkPanel: some View {
        panel {
            HStack(spacing: 12) {
                VStack(spacing: 8) {
                    MetricsFigure("Send Speed", value: MetricsFormat.rate(point?.networkSend))
                    MetricsFigure("Receive Speed", value: MetricsFormat.rate(point?.networkReceive))
                }
                VStack(spacing: 8) {
                    MetricsFigure(
                        "Total Sent", value: MetricsFormat.bytes(point?.networkSentTotal), color: Color.orange)
                    MetricsFigure(
                        "Total Received", value: MetricsFormat.bytes(point?.networkReceivedTotal),
                        color: Color.green)
                }
                trafficRing
            }
            HStack(spacing: 6) {
                MetricsFigure("Retransmissions", value: MetricsFormat.percent(point?.tcpRetransmissionPercent))
                MetricsFigure("Active Opens", value: point?.tcp?.active?.formatted() ?? "—")
                MetricsFigure("Passive Opens", value: point?.tcp?.passive?.formatted() ?? "—")
                MetricsFigure("Failed Attempts", value: point?.tcp?.failures?.formatted() ?? "—")
            }
            ForEach(hardwareInterfaces) { interface in
                Divider()
                interfaceRow(interface)
            }
            if !virtualInterfaces.isEmpty {
                DisclosureGroup(isExpanded: $virtualInterfacesExpanded) {
                    VStack(spacing: 12) {
                        ForEach(virtualInterfaces) { interface in
                            Divider()
                            interfaceRow(interface)
                        }
                    }
                } label: {
                    HStack {
                        Text("Virtual Interfaces")
                        Spacer()
                        Text(virtualInterfaces.count.formatted()).monospacedDigit()
                    }.font(.caption).foregroundStyle(.secondary)
                }
                .tint(Color.secondary)
            }
        }
    }

    private func interfaceRow(_ device: MetricsDevicePoint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(device.id, systemImage: "network").font(.caption.bold())
                Spacer()
                Text(device.addresses.joined(separator: ", ")).font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1).help(device.addresses.joined(separator: "\n"))
            }
            HStack(spacing: 6) {
                MetricsFigure("Send Speed", value: MetricsFormat.rate(device.write))
                MetricsFigure("Receive Speed", value: MetricsFormat.rate(device.read))
                MetricsFigure("Total Sent", value: MetricsFormat.bytes(device.writeTotal))
                MetricsFigure("Total Received", value: MetricsFormat.bytes(device.readTotal))
            }
        }
    }

    private var trafficRing: some View {
        let sent = point?.networkSentTotal ?? 0
        let received = point?.networkReceivedTotal ?? 0
        let fraction = sent + received > 0 ? sent / (sent + received) : 0
        return ZStack {
            Circle().stroke(.quaternary, lineWidth: 4)
            if sent + received > 0 {
                Circle().trim(from: 0, to: fraction).stroke(Color.orange, lineWidth: 4)
                Circle().trim(from: fraction, to: 1).stroke(Color.green, lineWidth: 4)
            }
        }
        .rotationEffect(.degrees(-90)).frame(width: 34, height: 34)
        .accessibilityLabel(Text("Sent / Received Traffic"))
        .accessibilityValue(MetricsFormat.capacity(point?.networkSentTotal, point?.networkReceivedTotal))
    }

    private func filesystemPanel(_ filesystem: MetricsFilesystem) -> some View {
        let io = point?.blockDevices[filesystem.blockID]
        return panel {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(filesystem.mountPoint).font(.headline).lineLimit(1).help(filesystem.mountPoint)
                    Text(filesystem.device).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(
                        filesystem.device)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(filesystem.type.uppercased()).font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(MetricsFormat.capacity(filesystem.used, filesystem.total))
                        .font(.system(size: 10, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(
                            0.7)
                }
                capacityBar(filesystem.usedPercent)
            }
            MetricsDiskTable(io: io)
        }
    }

    private func capacityBar(_ percent: Double?) -> some View {
        let color =
            (percent ?? 0) >= 90
            ? Color.red : (percent ?? 0) >= 75 ? Color.orange : Color.green
        return RoundedRectangle(cornerRadius: 3).fill(.quaternary)
            .overlay(alignment: .bottom) {
                if let percent {
                    RoundedRectangle(cornerRadius: 3).fill(color).frame(height: 36 * min(1, max(0, percent / 100)))
                }
            }
            .frame(width: 8, height: 36)
            .accessibilityLabel(Text("Disk Usage"))
            .accessibilityValue(MetricsFormat.percent(percent))
    }

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1)
            }
    }

}
