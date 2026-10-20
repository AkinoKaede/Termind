// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Charts
import SwiftUI
import TermindApplication

/// Compact connection summary and a rolling latency chart, following the peer diagnostics layout.
struct TailscalePingSection: View {
    @Binding var pinging: Bool
    let result: TailscalePingResult?
    let error: String?
    let history: [Double]
    let isAvailable: Bool

    private var routeColor: Color {
        switch result?.route {
        case .direct: .green
        case .peerRelay: .blue
        case .derp: .orange
        case .unknown, nil: .secondary
        }
    }

    var body: some View {
        Section {
            if let result {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    connectionLabel(result.route)
                        .foregroundStyle(routeColor)
                    Spacer()
                    (Text(result.milliseconds, format: .number.precision(.fractionLength(1)))
                        + Text(verbatim: " ms"))
                        .font(.headline.monospacedDigit())
                }
                switch result.route {
                case .direct(let endpoint):
                    TailscaleFormRow(label: AppStrings.Tailscale.endpoint) {
                        Text(verbatim: endpoint).textSelection(.enabled)
                    }
                case .peerRelay(let relay):
                    TailscaleFormRow(label: AppStrings.Tailscale.peerRelay) {
                        Text(verbatim: relay).textSelection(.enabled)
                    }
                case .derp(let region):
                    TailscaleFormRow(label: AppStrings.Tailscale.derpRegion) {
                        Text(verbatim: region).textSelection(.enabled)
                    }
                case .unknown: EmptyView()
                }
                if pinging { latencyChart }
            }
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            } else if pinging, result == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AppStrings.Connections.connecting).foregroundStyle(.secondary)
                }
            } else if result == nil {
                Text(AppStrings.Tailscale.noPingData).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(AppStrings.Tailscale.ping)
                Spacer()
                Button {
                    pinging.toggle()
                } label: {
                    Image(systemName: pinging ? "stop.fill" : "play.fill")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!pinging && !isAvailable)
                .accessibilityLabel((pinging ? AppStrings.Tailscale.stopPing : AppStrings.Tailscale.ping).swiftUIKey)
            }
            .textCase(nil)
        }
    }

    @ViewBuilder private func connectionLabel(_ route: TailscalePingResult.Route) -> some View {
        switch route {
        case .direct: Label(AppStrings.Tailscale.directConnection.swiftUIKey, systemImage: "arrow.right")
        case .peerRelay:
            Label(AppStrings.Tailscale.peerRelayConnection.swiftUIKey, systemImage: "arrow.triangle.2.circlepath")
        case .derp:
            Label(AppStrings.Tailscale.derpConnection.swiftUIKey, systemImage: "arrow.triangle.2.circlepath")
        case .unknown: Label(AppStrings.Tailscale.unknownRoute.swiftUIKey, systemImage: "questionmark.circle")
        }
    }

    private var latencyChart: some View {
        let ceiling = max((history.max() ?? 0) * 1.2, 1)
        return Chart {
            ForEach(Array(history.enumerated()), id: \.offset) { index, latency in
                LineMark(
                    x: .value(String(localized: AppStrings.Tailscale.ping), index),
                    y: .value(String(localized: AppStrings.Tailscale.latency), latency)
                )
                .foregroundStyle(routeColor)
                if history.count == 1 {
                    PointMark(
                        x: .value(String(localized: AppStrings.Tailscale.ping), index),
                        y: .value(String(localized: AppStrings.Tailscale.latency), latency)
                    ).foregroundStyle(routeColor)
                }
            }
        }
        .chartXScale(domain: 0...29)
        .chartYScale(domain: 0...ceiling)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, ceiling / 3, ceiling * 2 / 3, ceiling]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let latency = value.as(Double.self) {
                        Text(latency, format: .number.precision(.fractionLength(0))) + Text(verbatim: " ms")
                    }
                }
            }
        }
        .frame(height: 80)
        .accessibilityLabel(AppStrings.Tailscale.latency.swiftUIKey)
    }
}
