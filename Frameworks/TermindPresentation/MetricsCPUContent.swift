import SwiftUI
import TermindDomain

struct MetricsCPUContent: View {
    let point: MetricsPoint?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(MetricsFormat.percent(point?.cpu))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 104, height: 40, alignment: .leading)
            cpuLegend
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        cpuBars
        HStack {
            MetricsFigure("Cores", value: point?.coreCount.map(String.init) ?? "—")
            MetricsFigure("Idle", value: MetricsFormat.percent(point?.cpuUsage.idle))
            MetricsFigure("Uptime", value: uptime)
        }
        LabeledContent(
            "Load Average",
            value: point?.load.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(
                separator: " / ") ?? "—"
        )
        .font(.caption2).foregroundStyle(.secondary)
    }

    private var cpuLegend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                legend("System", value: point?.cpuUsage.system, color: Color.red)
                legend("User", value: point?.cpuUsage.user, color: Color.green)
                legend("I/O Wait", value: point?.cpuUsage.wait, color: .purple)
                stealLegend
            }
            .fixedSize(horizontal: true, vertical: false)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    legend("System", value: point?.cpuUsage.system, color: Color.red)
                    legend("User", value: point?.cpuUsage.user, color: Color.green)
                }
                GridRow {
                    legend("I/O Wait", value: point?.cpuUsage.wait, color: .purple)
                    stealLegend
                }
            }
        }
    }

    private var stealLegend: some View {
        legend("Steal", value: point?.cpuUsage.steal, color: Color.orange)
            .help("Steal: time a virtual CPU is ready to run but waiting for the hypervisor.")
    }

    private func legend(_ title: LocalizedStringResource, value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Rectangle().fill(color).frame(width: 3, height: 6)
                Text(title).lineLimit(1)
            }
            .font(.system(size: 8)).foregroundStyle(.secondary)
            Text(MetricsFormat.percent(value)).font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        // Reserve enough room for 100.0% so sampling never shifts the columns.
        .frame(minWidth: 40, maxWidth: .infinity, alignment: .leading)
    }

    private var cpuBars: some View {
        Group {
            if let cores = point?.cpuCores, !cores.isEmpty {
                VStack(spacing: 3) {
                    ForEach(cores) { cpu in
                        cpuBar(cpu.usage)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(AppStrings.Metrics.cpuCore(cpu.id)))
                            .accessibilityValue(MetricsFormat.percent(cpu.usage.utilization))
                    }
                }
            } else {
                cpuBar(point?.cpuUsage ?? MetricsCPUUsage())
                    .accessibilityLabel(Text(AppStrings.Metrics.cpuTimeBreakdown))
                    .accessibilityValue(MetricsFormat.percent(point?.cpu))
            }
        }
    }

    private func cpuBar(_ cpu: MetricsCPUUsage) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<48, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(cpuColor(at: Double(index) / 48 * 100, cpu: cpu))
            }
        }.frame(height: 8)
    }

    private func cpuColor(at position: Double, cpu: MetricsCPUUsage) -> Color {
        guard cpu.utilization != nil else { return Color.secondary.opacity(0.2) }
        var boundary = cpu.system ?? 0
        if position < boundary { return Color.red }
        boundary += cpu.user ?? 0
        if position < boundary { return Color.green }
        boundary += cpu.wait ?? 0
        if position < boundary { return .purple }
        boundary += cpu.steal ?? 0
        if position < boundary { return Color.orange }
        return Color.secondary.opacity(0.2)
    }

    private var uptime: String {
        guard let seconds = point?.uptime, seconds >= 0, seconds < Double(Int64.max) else { return "—" }
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }
}
