import SwiftUI
import TermindDomain

/// Shared horizontal instruments and stable-height connection state, without a card surface.
struct MetricsInstrumentBody: View {
    let server: ServerMetric
    let sleeping: Bool

    private var showsMetrics: Bool {
        !server.isConnecting && server.point != nil && !server.needsAttention
            && server.selection.enabled && !sleeping
            && (server.status.isEmpty || server.status == String(localized: "Live"))
    }

    var body: some View {
        ZStack {
            if showsMetrics {
                instruments
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
                        .multilineTextAlignment(.center).lineLimit(2)
                }
                .frame(maxWidth: .infinity)
                .help(connectionLabel)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .contentShape(Rectangle())
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
                .foregroundStyle((value ?? 0) > 0 ? TermindColor.success : TermindColor.secondaryForeground)
                .lineLimit(1).minimumScaleFactor(0.7)
            Label(title, systemImage: symbol).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

}
