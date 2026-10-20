// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct ServerMetricsView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @State private var detailObserver = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedServer: ServerMetric? {
        app.serverMetrics.servers.first(where: { $0.id == window.metricsHostID })
    }

    var body: some View {
        ZStack {
            if let server = selectedServer {
                Group {
                    if server.showsConnectionJourney && !server.isHostLocked {
                        MetricsJourneyView(server: server, model: app.serverMetrics)
                    } else {
                        detail(server)
                    }
                }
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)))
            } else {
                MetricsManagedCardPage()
                    .transition(.opacity)
            }
        }
        .clipped()
        .animation(Motion.panel(reduceMotion: reduceMotion), value: window.metricsHostID)
        .animation(Motion.panel(reduceMotion: reduceMotion), value: selectedServer?.showsConnectionJourney)
        .background(TermindColor.windowSurface)
        .onAppear { observeDetails() }
        .onChange(of: window.metricsHostID) { observeDetails() }
        .onChange(of: selectedServer?.showsConnectionJourney) { observeDetails() }
        .onChange(of: app.serverMetrics.servers.map(\.id)) { _, ids in
            if let id = window.metricsHostID, !ids.contains(id) { window.metricsHostID = nil }
        }
        .onDisappear { app.serverMetrics.stopObservingDetails(detailObserver) }
    }

    private func observeDetails() {
        if let server = selectedServer, !server.showsConnectionJourney {
            app.serverMetrics.observeDetails(hostID: server.id, observer: detailObserver)
        } else {
            app.serverMetrics.stopObservingDetails(detailObserver)
        }
    }

    private func detail(_ server: ServerMetric) -> some View {
        MetricsDetailView(server: server)
    }

}

struct MetricsDetailView: View {
    let server: ServerMetric
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    var body: some View {
        if server.isHostLocked {
            Button {
                app.proAccess.presentPaywall()
            } label: {
                MetricsHostLockNotice()
                    .padding(24)
                    .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
        } else {
            detail
        }
    }

    private var detail: some View {
        GeometryReader { geometry in
            let split = MetricsDetailPage.showsBothColumns(width: geometry.size.width)
            let showsStatus = split || window.metricsDetailPage == .status
            let showsProcesses = split || window.metricsDetailPage == .processes

            MetricsDetailLayout(split: split, page: window.metricsDetailPage) {
                ScrollView {
                    MetricsServerDetails(server: server)
                        .padding(1)
                }
                .metricsPlainScrollEdges()
                .opacity(showsStatus ? 1 : 0)
                .allowsHitTesting(showsStatus)
                .disabled(!showsStatus)
                .accessibilityHidden(!showsStatus)

                MetricsProcessList(server: server)
                    .opacity(showsProcesses ? 1 : 0)
                    .allowsHitTesting(showsProcesses)
                    .disabled(!showsProcesses)
                    .accessibilityHidden(!showsProcesses)
            }
            .padding(16)
            .clipped()
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            window.metricsDetailWidth = $0
        }
    }
}

struct ServerMetricsCard: View {
    let server: ServerMetric
    let model: ServerMetricsModel
    var compact = false
    var inspect: (() -> Void)?
    var upgrade: (() -> Void)?
    var openTerminal: (() -> Void)?
    var isSelected = false
    var select: (() -> Void)?
    var extendSelection: (() -> Void)?
    var contextActionItems: [ServerMetric] = []
    @State private var configuring = false

    var body: some View {
        CardTile(
            selectionID: server.id, isSelected: isSelected,
            select: select ?? {}, extendSelection: extendSelection,
            activate: activate, activatesOnReturn: !compact, activatesOnSingleClick: true
        ) {
            cardContent
        }
        .contextMenu {
            if contextActionItems.count > 1 {
                if contextActionItems.contains(where: { $0.selection.enabled }) {
                    Button(AppStrings.Metrics.pause.swiftUIKey, systemImage: MenuSymbol.pause) {
                        for item in contextActionItems where item.selection.enabled {
                            model.setEnabled(false, for: item)
                        }
                    }
                }
                if contextActionItems.contains(where: { !$0.selection.enabled }) {
                    Button(AppStrings.Metrics.resume.swiftUIKey, systemImage: MenuSymbol.start) {
                        for item in contextActionItems where !item.selection.enabled {
                            model.setEnabled(true, for: item)
                        }
                    }
                }
                Button(AppStrings.Common.retry.swiftUIKey, systemImage: MenuSymbol.refresh) {
                    for item in contextActionItems { model.retry(item) }
                }
                Divider()
                DestructiveMenuButton(AppStrings.Common.delete) {
                    for item in contextActionItems { model.remove(item.id) }
                }
            } else {
                singleServerMenu
            }
        }
        .sheet(isPresented: $configuring) {
            MetricsDevicePicker(server: server, model: model)
                .allowsApplicationTerminationWhenModal()
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if select == nil, inspect != nil {
                    Button(action: activate) { Text(server.name).font(.subheadline.bold()).lineLimit(1) }.buttonStyle(
                        .plain)
                } else {
                    Text(server.name).font(.subheadline.bold()).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let openTerminal {
                    Button(action: openTerminal) { Image(systemName: "terminal") }
                        .buttonStyle(.plain).foregroundStyle(TermindColor.secondaryForeground).help(
                            AppStrings.Metrics.openTerminal.swiftUIKey)
                }
                if !compact {
                    Menu {
                        singleServerMenu
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            if server.isHostLocked {
                MetricsHostLockNotice()
            } else if select == nil, let inspect {
                Button(action: inspect) { cardBody }.buttonStyle(.plain)
            } else {
                cardBody
            }

        }
    }

    func activate() {
        if server.isHostLocked { upgrade?() } else { inspect?() }
    }

    @ViewBuilder
    private var singleServerMenu: some View {
        if inspect != nil {
            Button(AppStrings.Metrics.details.swiftUIKey, systemImage: MenuSymbol.details, action: activate)
        }
        Button(
            server.selection.enabled ? AppStrings.Metrics.pause.swiftUIKey : AppStrings.Metrics.resume.swiftUIKey,
            systemImage: server.selection.enabled ? MenuSymbol.pause : MenuSymbol.start
        ) {
            model.setEnabled(!server.selection.enabled, for: server)
        }
        Button(AppStrings.Common.retry.swiftUIKey, systemImage: MenuSymbol.refresh) { model.retry(server) }
        Button(AppStrings.Metrics.selectDevices.swiftUIKey, systemImage: MenuSymbol.selectDevices) {
            configuring = true
        }
        Divider()
        DestructiveMenuButton(AppStrings.Common.delete) { model.remove(server.id) }
    }

    private var cardBody: some View {
        MetricsInstrumentBody(server: server, sleeping: model.sleeping)
    }

}

struct MetricsProcessList: View {
    let server: ServerMetric
    @Environment(WindowModel.self) private var window
    @State private var sortOrder = [KeyPathComparator(\MetricsProcess.cpuSortValue, order: .reverse)]
    private var rows: [MetricsProcess] {
        let query = window.metricsProcessQuery
        return server.processes.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || String($0.pid).contains(query)
        }.sorted(using: sortOrder)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppStrings.Metrics.processes).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            if server.processesDate == nil {
                VStack(spacing: 12) {
                    if server.processesFailed {
                        Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(
                            TermindColor.warning)
                        Text(AppStrings.Metrics.processMetricsUnavailable).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.regular)
                        Text(AppStrings.Metrics.collectingProcessesProgress).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if server.processesFailed {
                    Text(AppStrings.Metrics.processMetricsUnavailableShowingTheLastSample).font(.caption)
                        .foregroundStyle(
                            TermindColor.warning)
                }
                processTable
            }
        }
        .padding(12)
        .background(TermindColor.windowSurface, in: RoundedRectangle(cornerRadius: Metrics.Radius.large))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.large).strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    private var processTable: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn(AppStrings.Metrics.pid.swiftUIKey, value: \.pid) { process in
                Text(String(process.pid)).foregroundStyle(.secondary).frame(height: 28)
            }
            .width(48)
            TableColumn(AppStrings.Metrics.process.swiftUIKey, value: \.name) { process in
                Text(process.name).lineLimit(1).truncationMode(.tail).help(process.name).frame(height: 28)
            }.width(min: 0, ideal: 180)
            TableColumn(AppStrings.Metrics.cpu.swiftUIKey, value: \.cpuSortValue) { process in
                Text(MetricsFormat.percent(process.cpu)).frame(height: 28)
            }.width(
                58)
            TableColumn(AppStrings.Metrics.memory.swiftUIKey, value: \.memorySortValue) { process in
                Text(MetricsFormat.bytes(process.memory, style: .memory)).frame(height: 28)
            }
            .width(72)
        }
        .font(.system(size: 11, design: .monospaced))
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MetricsDevicePicker: View {
    let server: ServerMetric
    let model: ServerMetricsModel
    @Environment(\.dismiss) private var dismiss
    @State private var disks: Set<String> = []
    @State private var interfaces: Set<String> = []
    @State private var allDisks = true
    @State private var allInterfaces = true
    var body: some View {
        Form {
            Section(AppStrings.Metrics.disks.swiftUIKey) {
                Toggle(AppStrings.Metrics.allDefaultDisks.swiftUIKey, isOn: $allDisks)
                ForEach(server.disks, id: \.self) { name in
                    Toggle(name, isOn: selected(name, in: $disks)).disabled(allDisks)
                }
            }
            Section(AppStrings.Metrics.networkInterfaces.swiftUIKey) {
                Toggle(AppStrings.Metrics.defaultNetworkInterfaces.swiftUIKey, isOn: $allInterfaces)
                ForEach(server.interfaces, id: \.self) { name in
                    Toggle(name, isOn: selected(name, in: $interfaces)).disabled(allInterfaces)
                }
            }
            HStack {
                Button(AppStrings.Common.cancel.swiftUIKey) { dismiss() }
                Spacer()
                Button(AppStrings.Common.save.swiftUIKey) {
                    model.selectDevices(
                        server, disks: allDisks ? nil : disks, interfaces: allInterfaces ? nil : interfaces)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped).frame(width: 440, height: 440)
        .onAppear {
            allDisks = server.selection.disks == nil
            allInterfaces = server.selection.interfaces == nil
            disks = server.selection.disks ?? Set(server.disks)
            interfaces = server.selection.interfaces ?? Set(server.interfaces)
        }
    }
    private func selected(_ name: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(name) },
            set: {
                if $0 { set.wrappedValue.insert(name) } else { set.wrappedValue.remove(name) }
            })
    }
}

struct MetricsMenuView: View {
    let model: ServerMetricsModel
    let openMetrics: () -> Void
    let openDetails: (UUID) -> Void

    static func preferredSize(serverCount: Int) -> CGSize {
        CGSize(width: 380, height: serverCount == 0 ? 140 : min(520, serverCount * 118 + max(0, serverCount - 1)) + 49)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(ApplicationIdentity.displayName).font(.headline)
                Spacer()
                Button(action: openMetrics) {
                    Image(systemName: "macwindow").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).termindInputAwareFocusEffect()
                .help(Text(AppStrings.Metrics.openTermind)).accessibilityLabel(Text(AppStrings.Metrics.openTermind))
                Button(action: { NSApp.terminate(nil) }) {
                    Image(systemName: "power").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).termindInputAwareFocusEffect()
                .help(Text(AppStrings.Metrics.quitTermind)).accessibilityLabel(Text(AppStrings.Metrics.quitTermind))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if model.servers.isEmpty {
                Text(AppStrings.Metrics.noMonitoredServers).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.servers) { server in
                            Button {
                                openDetails(server.id)
                            } label: {
                                MetricsMenuRow(server: server, sleeping: model.sleeping)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain).termindInputAwareFocusEffect()
                            .help(Text(AppStrings.Metrics.details))
                            .accessibilityLabel(Text(server.name))
                            .accessibilityIdentifier("metrics.menu.\(server.id)")
                            if server.id != model.servers.last?.id { Divider() }
                        }
                    }
                }
                .contentMargins(0, for: .scrollContent)
                .scrollContentBackground(.hidden)
                .metricsPlainScrollEdges(.all)
                .frame(height: Self.preferredSize(serverCount: model.servers.count).height - 49)
            }
        }
        .frame(
            width: Self.preferredSize(serverCount: model.servers.count).width,
            height: Self.preferredSize(serverCount: model.servers.count).height)
    }
}

private struct MetricsMenuRow: View {
    let server: ServerMetric
    let sleeping: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(server.name).font(.subheadline.bold()).lineLimit(1).help(server.name)
                .frame(height: 18, alignment: .leading)
            if server.isHostLocked {
                MetricsHostLockNotice()
            } else {
                MetricsInstrumentBody(server: server, sleeping: sleeping)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 118)
    }
}

extension View {
    @ViewBuilder fileprivate func metricsPlainScrollEdges(_ edges: Edge.Set = .bottom) -> some View {
        if #available(macOS 26.0, *) { self.scrollEdgeEffectHidden(true, for: edges) } else { self }
    }
}
