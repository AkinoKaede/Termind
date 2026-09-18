import SwiftUI
import TermindApplication

/// Connection failures stay actionable even though healthy metrics need no status footer.
struct MetricsConnectionNotice: View {
    let server: ServerMetric
    let model: ServerMetricsModel

    var body: some View {
        if !server.status.isEmpty, server.status != String(localized: "Live") {
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
            Picker("Details", selection: $window.metricsDetailPage) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .accessibilityLabel("Status").help("Status").tag(MetricsDetailPage.status)
                Image(systemName: "list.bullet.rectangle")
                    .accessibilityLabel("Processes").help("Processes").tag(MetricsDetailPage.processes)
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
                .help(server.selection.enabled ? Text("Pause") : Text("Resume"))
        }
        Menu {
            if window.showsCompactMetricsDetail { pauseButton }
            Button("Retry", systemImage: MenuSymbol.refresh) { model.retry(server) }
            Button("Select Devices", systemImage: MenuSymbol.selectDevices) { configuring = true }
            Divider()
            DestructiveMenuButton("Delete") {
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
                server.selection.enabled ? "Pause" : "Resume", systemImage: server.selection.enabled ? "pause" : "play")
        }
    }
}
