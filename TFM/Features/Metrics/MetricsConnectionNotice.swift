import SwiftUI
import TermindApplication
import TermindPresentation

/// Connection failures stay actionable even though healthy metrics need no status footer.
struct MetricsConnectionNotice: View {
    let server: ServerMetric

    var body: some View {
        if !server.status.isEmpty, server.status != String(localized: TermindCopy.Metrics.live) {
            HStack(spacing: 6) {
                if server.isConnecting { ProgressView().controlSize(.mini) }
                Text(server.status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct MetricsDetailPagePicker: View {
    @Environment(WindowModel.self) private var window

    var body: some View {
        @Bindable var window = window
        if window.showsCompactMetricsDetail {
            Picker(TermindCopy.Metrics.details.swiftUIKey, selection: $window.metricsDetailPage) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .accessibilityLabel(TermindCopy.Common.status.swiftUIKey).help(TermindCopy.Common.status.swiftUIKey)
                    .tag(MetricsDetailPage.status)
                Image(systemName: "list.bullet.rectangle")
                    .accessibilityLabel(TermindCopy.Metrics.processes.swiftUIKey).help(
                        TermindCopy.Metrics.processes.swiftUIKey
                    ).tag(MetricsDetailPage.processes)
            }
            .pickerStyle(.segmented)
            .frame(width: 104)
        }
    }
}

struct MetricsDetailToolbar: View {
    let server: ServerMetric
    let model: ServerMetricsModel
    @Environment(WindowModel.self) private var window
    @State private var configuring = false

    var body: some View {
        if !window.showsCompactMetricsDetail {
            pauseButton.labelStyle(.iconOnly)
                .help(server.selection.enabled ? Text(TermindCopy.Metrics.pause) : Text(TermindCopy.Metrics.resume))
        }
        Menu {
            if window.showsCompactMetricsDetail { pauseButton }
            Button(TermindCopy.Common.retry.swiftUIKey, systemImage: MenuSymbol.refresh) { model.retry(server) }
            Button(TermindCopy.Metrics.selectDevices.swiftUIKey, systemImage: MenuSymbol.selectDevices) {
                configuring = true
            }
            Divider()
            DestructiveMenuButton(TermindCopy.Common.delete) {
                model.remove(server.id)
                window.metricsHostID = nil
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .sheet(isPresented: $configuring) { MetricsDevicePicker(server: server, model: model) }
    }

    private var pauseButton: some View {
        Button {
            model.setEnabled(!server.selection.enabled, for: server)
        } label: {
            Label(
                server.selection.enabled ? TermindCopy.Metrics.pause.swiftUIKey : TermindCopy.Metrics.resume.swiftUIKey,
                systemImage: server.selection.enabled ? "pause" : "play")
        }
    }
}
