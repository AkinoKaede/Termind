import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct MobileMetricsView: View {
    let app: MobileAppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selecting = false
    @State private var selectedID: UUID?

    var body: some View {
        MobileCardPage {
            if app.metrics.servers.isEmpty {
                ContentUnavailableView(
                    "No monitored servers", systemImage: "waveform.path.ecg",
                    description: Text("Add a saved Linux server to start monitoring."))
            }
            MobileCardGrid {
                ForEach(app.metrics.servers) { server in
                    MobileActionCard {
                        selectedID = server.id
                    } content: {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(server.name).font(.subheadline.bold()).lineLimit(1)
                            MetricsInstrumentBody(
                                server: server, sleeping: app.metrics.core.sleeping,
                                layout: typeSize.isAccessibilitySize ? .adaptive : .horizontal)
                        }
                    } actions: {
                        Button(
                            server.selection.enabled ? "Pause" : "Resume",
                            systemImage: server.selection.enabled ? "pause" : "play"
                        ) {
                            app.metrics.core.setEnabled(!server.selection.enabled, for: server)
                        }
                        Button("Retry", systemImage: "arrow.clockwise") { app.metrics.core.retry(server) }
                        Divider()
                        Button("Remove", systemImage: "trash", role: .destructive) { app.metrics.remove(server.id) }
                    }
                }
            }
        }
        .navigationTitle("Metrics")
        .toolbar { Button("Add Server", systemImage: "plus") { selecting = true }.labelStyle(.iconOnly) }
        .navigationDestination(item: $selectedID) { id in
            if let server = app.metrics.servers.first(where: { $0.id == id }) {
                MobileMetricsDetailView(app: app, server: server)
            }
        }
        .sheet(isPresented: $selecting) {
            NavigationStack {
                MobileHostPicker(
                    library: app.library,
                    title: "Add Server",
                    emptyDescription: "Add a saved Linux server to start monitoring.",
                    cancel: { selecting = false },
                    select: { host in
                        selecting = false
                        if !app.metrics.add(host.id, pro: app.pro.hasProAccess) {
                            if let error = app.metrics.core.storageError {
                                app.error = error
                            } else {
                                app.pro.presentPaywall(for: .unlimitedMetrics)
                            }
                        }
                    })
            }.mobileSheetPresentation(compact: true)
        }
        .task { app.metrics.start() }
    }
}

struct MobileMetricsDetailView: View {
    let app: MobileAppModel
    let server: ServerMetric
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobileToolbarLayout) private var toolbarLayout
    @State private var page = MobileMetricsDetailPage.status
    @State private var observer = UUID()
    @State private var showsBothPanels = false

    var body: some View {
        Group {
            if server.showsConnectionJourney {
                MobileConnectionJourneyView(
                    journey: server.journey, library: app.library,
                    authenticationPrompt: server.authenticationPrompt, hostKey: server.hostKeyPrompt,
                    reconnectState: nil,
                    submit: { identity, username, password, passphrase, key, save in
                        app.metrics.core.submitAuthentication(
                            server, identityID: identity, username: username,
                            password: password, passphrase: passphrase, keyID: key, save: save)
                    },
                    accept: { remember in
                        if let observation = server.hostKey {
                            app.metrics.core.acceptHostKey(server, observation: observation, remember: remember)
                        }
                    }, retry: { app.metrics.core.retry(server) },
                    retryReconnectNow: {}, stopReconnecting: {},
                    cancel: cancelAuthentication,
                    keyboardAuthentication: server.keyboardAuthentication,
                    cancelKeyboardAuthentication: cancelAuthentication)
            } else {
                MobileRegionReader { regions in
                    let panels = MobileMetricsPanels(regions: regions, page: page)
                    MobilePaneLayout(frames: [panels.status, panels.processes]) {
                        ScrollView { MetricsSystemPanels(server: server).padding() }
                            .opacity(panels.status == nil ? 0 : 1)
                            .allowsHitTesting(panels.status != nil)
                            .accessibilityHidden(panels.status == nil)
                            .clipped()
                        MobileMetricsProcessesView(server: server)
                            .opacity(panels.processes == nil ? 0 : 1)
                            .allowsHitTesting(panels.processes != nil)
                            .accessibilityHidden(panels.processes == nil)
                            .clipped()
                    }
                    .onChange(of: panels.showsBoth, initial: true) { _, value in showsBothPanels = value }
                }
            }
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: toolbarLayout.usesIconSwitcher ? .title : nil)
        .toolbar {
            if !server.showsConnectionJourney && !showsBothPanels {
                if toolbarLayout.isVertical {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            pagePicker
                        } label: {
                            Label("Details", systemImage: page.systemImage)
                        }
                        .labelStyle(.iconOnly)
                    }
                    .mobileProminentAction()
                } else {
                    ToolbarItem(placement: .principal) {
                        pagePicker.pickerStyle(.segmented).labelStyle(.iconOnly).frame(width: 104)
                    }
                }
            }
            MobileToolbarOverflow(title: "Metrics") {
                Button(
                    server.selection.enabled ? "Pause" : "Resume",
                    systemImage: server.selection.enabled ? "pause" : "play"
                ) {
                    app.metrics.core.setEnabled(!server.selection.enabled, for: server)
                }
                Button("Retry", systemImage: "arrow.clockwise") { app.metrics.core.retry(server) }
            }
        }
        .onAppear { observe() }
        .onChange(of: server.showsConnectionJourney) { observe() }
        .onDisappear { app.metrics.core.stopObservingDetails(observer) }
    }

    private var pagePicker: some View {
        Picker("Details", selection: $page) {
            Label("Status", systemImage: MobileMetricsDetailPage.status.systemImage).tag(MobileMetricsDetailPage.status)
            Label("Processes", systemImage: MobileMetricsDetailPage.processes.systemImage).tag(
                MobileMetricsDetailPage.processes)
        }
    }

    private func cancelAuthentication() {
        app.metrics.core.setEnabled(false, for: server)
        dismiss()
    }

    private func observe() {
        if server.showsConnectionJourney {
            app.metrics.core.stopObservingDetails(observer)
        } else {
            app.metrics.core.observeDetails(hostID: server.id, observer: observer)
        }
    }
}

nonisolated enum MobileMetricsDetailPage: CaseIterable {
    case status, processes
    static func showsBothColumns(width: CGFloat) -> Bool { width >= 700 }
    var systemImage: String {
        switch self {
        case .status: "gauge.with.dots.needle.33percent"
        case .processes: "list.bullet.rectangle"
        }
    }
}

nonisolated struct MobileMetricsPanels {
    var status: CGRect?
    var processes: CGRect?
    var showsBoth: Bool { status != nil && processes != nil }

    init(regions: MobileContentRegions, page: MobileMetricsDetailPage) {
        if let split = regions.split {
            status = split.first
            processes = split.second
        } else if !regions.hasActiveDivision
            && MobileMetricsDetailPage.showsBothColumns(width: regions.continuous.width)
        {
            let bounds = regions.continuous
            let statusWidth = min(360, bounds.width * 0.4)
            status = CGRect(x: bounds.minX, y: bounds.minY, width: statusWidth, height: bounds.height)
            processes = CGRect(
                x: bounds.minX + statusWidth + 16, y: bounds.minY,
                width: bounds.width - statusWidth - 32, height: bounds.height)
        } else if MobileContentRegions.isUsable(regions.continuous) {
            status = page == .status ? regions.continuous : nil
            processes = page == .processes ? regions.continuous : nil
        }
    }
}

private struct MobileMetricsProcessesView: View {
    let server: ServerMetric
    @State private var sort = ProcessSort.cpu
    enum ProcessSort: String, CaseIterable { case cpu, memory, pid }
    private var rows: [MetricsProcess] {
        server.processes.sorted {
            switch sort {
            case .cpu: ($0.cpu ?? -1) > ($1.cpu ?? -1)
            case .memory: ($0.memory ?? -1) > ($1.memory ?? -1)
            case .pid: $0.pid < $1.pid
            }
        }
    }
    var body: some View {
        List {
            Picker("Sort By", selection: $sort) {
                Text("CPU").tag(ProcessSort.cpu)
                Text("Memory").tag(ProcessSort.memory)
                Text("PID").tag(ProcessSort.pid)
            }
            if server.processesFailed { Text("Process metrics unavailable").foregroundStyle(.secondary) }
            ForEach(rows) { process in
                HStack {
                    Text(String(process.pid))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 64, alignment: .leading)
                        .layoutPriority(1)
                    Text(process.name).lineLimit(1)
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing) {
                        Text(MetricsFormat.percent(process.cpu))
                        Text(MetricsFormat.bytes(process.memory)).foregroundStyle(.secondary)
                    }.font(.caption.monospaced())
                }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemBackground))
    }
}
