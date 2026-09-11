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
            panel {
                HStack(alignment: .top, spacing: 10) {
                    Text(MetricsFormat.percent(point?.cpu))
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            legend("System", value: point?.cpuSystem, color: Color.red)
                            legend("User", value: point?.cpuUser, color: Color.green)
                        }
                        HStack {
                            legend("I/O Wait", value: point?.cpuWait, color: .purple)
                            legend("Steal", value: point?.cpuSteal, color: Color.orange)
                                .help("Steal: time a virtual CPU is ready to run but waiting for the hypervisor.")
                        }
                    }
                }
                HStack(spacing: 2) {
                    ForEach(0..<48, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1).fill(cpuColor(at: Double(index) / 48 * 100))
                    }
                }.frame(height: 12).accessibilityLabel(Text("CPU time breakdown"))
                HStack {
                    figure("Cores", value: point?.coreCount.map(String.init) ?? "—")
                    figure("Idle", value: MetricsFormat.percent(point?.cpuIdle))
                    figure("Uptime", value: uptime)
                }
                LabeledContent(
                    "Load Average",
                    value: point?.load.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(
                        separator: " / ") ?? "—"
                )
                .font(.caption2).foregroundStyle(.secondary)
            }
            panel {
                HStack {
                    figure("Free Memory", value: MetricsFormat.bytes(point?.memoryFree))
                    figure("Used", value: MetricsFormat.bytes(point?.memoryUsed))
                    figure("Page Cache", value: MetricsFormat.bytes(point?.memoryCached))
                    MetricsRing(title: "Memory", value: point?.memory)
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
                    figure("Send Speed", value: MetricsFormat.rate(point?.networkSend))
                    figure("Receive Speed", value: MetricsFormat.rate(point?.networkReceive))
                }
                VStack(spacing: 8) {
                    figure(
                        "Total Sent", value: MetricsFormat.bytes(point?.networkSentTotal), color: Color.orange)
                    figure(
                        "Total Received", value: MetricsFormat.bytes(point?.networkReceivedTotal),
                        color: Color.green)
                }
                trafficRing
            }
            HStack(spacing: 6) {
                figure("Retransmissions", value: MetricsFormat.percent(point?.tcpRetransmissionPercent))
                figure("Active Opens", value: point?.tcp?.active?.formatted() ?? "—")
                figure("Passive Opens", value: point?.tcp?.passive?.formatted() ?? "—")
                figure("Failed Attempts", value: point?.tcp?.failures?.formatted() ?? "—")
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
                figure("Send Speed", value: MetricsFormat.rate(device.write))
                figure("Receive Speed", value: MetricsFormat.rate(device.read))
                figure("Total Sent", value: MetricsFormat.bytes(device.writeTotal))
                figure("Total Received", value: MetricsFormat.bytes(device.readTotal))
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

    private func figure(_ title: LocalizedStringKey, value: String, color: Color = Color.primary)
        -> some View
    {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legend(_ title: LocalizedStringKey, value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Rectangle().fill(color).frame(width: 3, height: 6)
                Text(title).lineLimit(1)
            }
            .font(.system(size: 8)).foregroundStyle(.secondary)
            Text(MetricsFormat.percent(value)).font(.system(size: 10, weight: .semibold, design: .monospaced))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cpuColor(at position: Double) -> Color {
        guard let point, point.cpu != nil else { return Color.secondary.opacity(0.2) }
        var boundary = point.cpuSystem ?? 0
        if position < boundary { return Color.red }
        boundary += point.cpuUser ?? 0
        if position < boundary { return Color.green }
        boundary += point.cpuWait ?? 0
        if position < boundary { return .purple }
        boundary += point.cpuSteal ?? 0
        if position < boundary { return Color.orange }
        return Color.secondary.opacity(0.2)
    }

    private var uptime: String {
        guard let seconds = point?.uptime, seconds >= 0, seconds < Double(Int64.max) else { return "—" }
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }
}
