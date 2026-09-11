import SwiftUI
import TermindApplication
import TermindDomain

/// Shared horizontal instruments and stable-height connection state, without a card surface.
public struct MetricsInstrumentBody: View {
    public enum Layout { case horizontal, adaptive }
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(server: ServerMetric, sleeping: Bool, layout: Layout = .horizontal) {
        self.server = server
        self.sleeping = sleeping
        self.layout = layout
    }
    let server: ServerMetric
    let sleeping: Bool
    let layout: Layout

    private var showsMetrics: Bool {
        !server.isConnecting && server.point != nil && !server.needsAttention
            && server.selection.enabled && !sleeping
            && (server.status.isEmpty || server.status == String(localized: "Live"))
    }

    public var body: some View {
        ZStack {
            if showsMetrics {
                if layout == .horizontal {
                    instruments
                } else {
                    adaptiveInstruments
                }
            } else {
                VStack(spacing: 7) {
                    if server.isConnecting
                        || (server.point == nil && !server.needsAttention
                            && server.selection.enabled && !sleeping)
                    {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: server.needsAttention ? "exclamationmark.triangle" : "pause.circle")
                            .foregroundStyle(.secondary)
                    }
                    Text(connectionLabel)
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).lineLimit(layout == .horizontal ? 2 : nil)
                }
                .frame(maxWidth: .infinity)
                .help(connectionLabel)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: layout == .horizontal ? 64 : nil)
        .frame(minHeight: 64)
        .contentShape(Rectangle())
    }

    private var adaptiveInstruments: some View {
        VStack(alignment: .leading, spacing: 12) {
            if typeSize.isAccessibilitySize {
                capacity("CPU", value: server.point?.cpu)
                capacity("Memory", value: server.point?.memory)
                adaptiveRates
            } else {
                HStack(alignment: .top, spacing: 12) {
                    capacity("CPU", value: server.point?.cpu)
                    capacity("Memory", value: server.point?.memory)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        networkRates
                        diskRates
                    }.fixedSize(horizontal: true, vertical: false)
                    adaptiveRates
                }
            }
        }
    }

    private var adaptiveRates: some View {
        VStack(alignment: .leading, spacing: 12) {
            networkRates
            diskRates
        }
    }

    private var networkRates: some View {
        VStack(alignment: .leading, spacing: 8) {
            adaptiveRate("Network Send", symbol: "arrow.up", value: server.point?.networkSend)
            adaptiveRate("Network Receive", symbol: "arrow.down", value: server.point?.networkReceive)
        }
    }

    private var diskRates: some View {
        VStack(alignment: .leading, spacing: 8) {
            adaptiveRate("Disk Read", symbol: "arrow.up.doc", value: server.point?.diskRead)
            adaptiveRate("Disk Write", symbol: "arrow.down.doc", value: server.point?.diskWrite)
        }
    }

    private func capacity(_ title: LocalizedStringKey, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(MetricsFormat.percent(value)).font(.headline.monospacedDigit())
            ProgressView(value: value.map { min(1, max(0, $0 / 100)) } ?? 0)
                .tint((value ?? 0) >= 90 ? .red : (value ?? 0) >= 75 ? .orange : .green)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func adaptiveRate(_ title: LocalizedStringKey, symbol: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(MetricsFormat.rate(value)).font(.subheadline.monospacedDigit())
        }.accessibilityElement(children: .combine)
    }

    private var connectionLabel: String {
        if server.requiresAuthentication { return String(localized: "Server Identity Verification Required") }
        return server.status
    }

    private var instruments: some View {
        HStack(alignment: .center, spacing: 12) {
            MetricsRing(title: "CPU", value: server.point?.cpu)
            MetricsRing(title: "Memory", value: server.point?.memory)
                .help(MetricsFormat.capacity(server.point?.memoryUsed, server.point?.memoryTotal))
            VStack(alignment: .leading, spacing: 6) {
                rate("Network Send", symbol: "arrow.up", value: server.point?.networkSend)
                rate("Network Receive", symbol: "arrow.down", value: server.point?.networkReceive)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                rate("Disk Read", symbol: "arrow.up.doc", value: server.point?.diskRead)
                rate("Disk Write", symbol: "arrow.down.doc", value: server.point?.diskWrite)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func rate(_ title: LocalizedStringKey, symbol: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(MetricsFormat.rate(value)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle((value ?? 0) > 0 ? Color.green : Color.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Label(title, systemImage: symbol).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

}
