// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindPresentation

/// Uses the same native selection, hover, marquee and drag renderer as Hosts.
struct MetricsManagedCardPage: ManagedCardPage {
    typealias SectionID = String
    typealias Item = ServerMetric

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    var managedMinimumCardWidth: CGFloat { 310 }
    var managedMaximumCardWidth: CGFloat { .infinity }
    private var filtered: [ServerMetric] {
        app.serverMetrics.servers.filter { server in
            window.metricsQuery.isEmpty || server.name.localizedCaseInsensitiveContains(window.metricsQuery)
                || app.hostLibrary.host(server.id)?.matches(window.metricsQuery) == true
        }
    }
    var managedSections: [ManagedCardSection<String, ServerMetric>] {
        [ManagedCardSection(id: "servers", title: "", items: filtered, showsWhenEmpty: false)]
    }
    var managedSelection: ManagedCardSelection<UUID> {
        ManagedCardSelection(selected: { window.metricsSelection }, update: { window.metricsSelection = $0 })
    }
    var managedCapabilities: ManagedCardCapabilities<String, UUID> {
        ManagedCardCapabilities(
            selection: .multiple, marqueeSelection: true,
            reordering: ManagedCardReordering(isEnabled: window.metricsQuery.isEmpty, dropPolicy: .sameSection) {
                ids, _, before in
                app.serverMetrics.move(ids, before: before)
            }
        )
    }
    var isManagedSourceEmpty: Bool { app.serverMetrics.servers.isEmpty }
    var managedPresentation: MetricsManagedPresentation {
        MetricsManagedPresentation(ids: Set(app.serverMetrics.servers.map(\.id)))
    }

    func managedCard(for item: ServerMetric, context: ManagedCardItemContext<ServerMetric>) -> some View {
        ServerMetricsCard(
            server: item, model: app.serverMetrics,
            inspect: { window.metricsHostID = item.id },
            upgrade: { app.proAccess.presentPaywall() },
            openTerminal: {
                if let host = app.hostLibrary.host(item.id) { app.open(host, as: .sshSession, in: window) }
            },
            isSelected: context.isSelected, select: context.select, extendSelection: context.extendSelection,
            contextActionItems: context.actionItems
        )

    }
    func managedHeader(for section: ManagedCardSection<String, ServerMetric>, isDropTarget: Bool) -> some View {
        EmptyView()
    }
    func managedEmptyState() -> some View {
        ContentUnavailableView(
            AppStrings.Metrics.noMonitoredServers.swiftUIKey, systemImage: "waveform.path.ecg",
            description: Text(AppStrings.Metrics.addASavedLinuxServerToStartMonitoring)
        )
    }
    func managedNoResultsState() -> some View { ContentUnavailableView.search(text: window.metricsQuery) }
}

struct MetricsManagedPresentation: ManagedCardPresentationModifier {
    let ids: Set<UUID>
    @Environment(WindowModel.self) private var window
    func body(content: Content) -> some View {
        content.onChange(of: ids) { window.metricsSelection.formIntersection(ids) }
    }
}
