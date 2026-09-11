import SwiftUI
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
                    if server.showsConnectionJourney {
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
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    MetricsServerDetails(server: server, model: app.serverMetrics)
                        .padding(1)
                }
                .frame(width: min(340, max(270, geometry.size.width * 0.38)))
                .metricsPlainScrollEdges()
                MetricsProcessList(server: server)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(16)
        }
        .frame(minWidth: 630)
    }

}

struct ServerMetricsCard: View {
    let server: ServerMetric
    let model: ServerMetricsModel
    var compact = false
    var inspect: (() -> Void)?
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
            activate: inspect, activatesOnReturn: !compact, activatesOnSingleClick: true
        ) {
            cardContent
        }
        .contextMenu {
            if contextActionItems.count > 1 {
                if contextActionItems.contains(where: { $0.selection.enabled }) {
                    Button("Pause", systemImage: MenuSymbol.pause) {
                        for item in contextActionItems where item.selection.enabled {
                            model.setEnabled(false, for: item)
                        }
                    }
                }
                if contextActionItems.contains(where: { !$0.selection.enabled }) {
                    Button("Resume", systemImage: MenuSymbol.start) {
                        for item in contextActionItems where !item.selection.enabled {
                            model.setEnabled(true, for: item)
                        }
                    }
                }
                Button("Retry", systemImage: MenuSymbol.refresh) {
                    for item in contextActionItems { model.retry(item) }
                }
                Divider()
                DestructiveMenuButton("Delete") {
                    for item in contextActionItems { model.remove(item.id) }
                }
            } else {
                singleServerMenu
            }
        }
        .sheet(isPresented: $configuring) { MetricsDevicePicker(server: server, model: model) }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if select == nil, let inspect {
                    Button(action: inspect) { Text(server.name).font(.subheadline.bold()).lineLimit(1) }.buttonStyle(
                        .plain)
                } else {
                    Text(server.name).font(.subheadline.bold()).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let openTerminal {
                    Button(action: openTerminal) { Image(systemName: "terminal") }
                        .buttonStyle(.plain).foregroundStyle(TermindColor.secondaryForeground).help("Open Terminal")
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
            if select == nil, let inspect {
                Button(action: inspect) { cardBody }.buttonStyle(.plain)
            } else {
                cardBody
            }

        }
    }

    @ViewBuilder
    private var singleServerMenu: some View {
        if let inspect { Button("Details", systemImage: MenuSymbol.details, action: inspect) }
        Button(
            server.selection.enabled ? "Pause" : "Resume",
            systemImage: server.selection.enabled ? MenuSymbol.pause : MenuSymbol.start
        ) {
            model.setEnabled(!server.selection.enabled, for: server)
        }
        Button("Retry", systemImage: MenuSymbol.refresh) { model.retry(server) }
        Button("Select Devices", systemImage: MenuSymbol.selectDevices) { configuring = true }
        Divider()
        DestructiveMenuButton("Delete") { model.remove(server.id) }
    }

    private var cardBody: some View {
        MetricsInstrumentBody(server: server, sleeping: model.sleeping)
    }

}

typealias MetricsRing = TermindPresentation.MetricsRing

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
            Text("Processes").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            if server.processesDate == nil {
                VStack(spacing: 12) {
                    if server.processesFailed {
                        Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(
                            TermindColor.warning)
                        Text("Process metrics unavailable").foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.regular)
                        Text("Collecting processes…").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if server.processesFailed {
                    Text("Process metrics unavailable; showing the last sample.").font(.caption).foregroundStyle(
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
            TableColumn("PID", value: \.pid) { process in
                Text(String(process.pid)).foregroundStyle(.secondary).frame(height: 28)
            }
            .width(48)
            TableColumn("Process", value: \.name) { process in
                Text(process.name).lineLimit(1).help(process.name).frame(height: 28)
            }.width(min: 80, ideal: 180)
            TableColumn("CPU", value: \.cpuSortValue) { process in
                Text(MetricsFormat.percent(process.cpu)).frame(height: 28)
            }.width(
                58)
            TableColumn("Memory", value: \.memorySortValue) { process in
                Text(MetricsFormat.bytes(process.memory)).frame(height: 28)
            }
            .width(72)
        }
        .font(.system(size: 11, design: .monospaced))
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

typealias MetricsFormat = TermindPresentation.MetricsFormat

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
            Section("Disks") {
                Toggle("All Default Disks", isOn: $allDisks)
                ForEach(server.disks, id: \.self) { name in
                    Toggle(name, isOn: selected(name, in: $disks)).disabled(allDisks)
                }
            }
            Section("Network Interfaces") {
                Toggle("Default Network Interfaces", isOn: $allInterfaces)
                ForEach(server.interfaces, id: \.self) { name in
                    Toggle(name, isOn: selected(name, in: $interfaces)).disabled(allInterfaces)
                }
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
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
                .help(Text("Open Termind")).accessibilityLabel(Text("Open Termind"))
                Button(action: MetricsWindowPresenter.quit) {
                    Image(systemName: "power").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).termindInputAwareFocusEffect()
                .help(Text("Quit Termind")).accessibilityLabel(Text("Quit Termind"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if model.servers.isEmpty {
                Text("No monitored servers").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.servers) { server in
                            MetricsMenuRow(server: server, sleeping: model.sleeping)
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
            MetricsInstrumentBody(server: server, sleeping: sleeping)
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
