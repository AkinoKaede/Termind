import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPresentation
import Testing

@testable import Termind

@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["TERMIND_HOST_ACCESS_UI_REVIEW"] == "1"),
    .serialized)
@MainActor
struct HostAccessUIReviewTests {
    @Test(.requiresVisibleWindow, arguments: ["en", "zh-Hans"])
    func renderHostAndMetricsLocks(language: String) async throws {
        NSApp.unhideWithoutActivation()
        let hosts = ["Production", "Staging", "Database", "Backup"].enumerated().map { index, name in
            TermindDomain.Host(
                name: name, host: "\(name.lowercased()).example.invalid",
                createdAt: Date(timeIntervalSince1970: Double(index)))
        }
        let library = HostLibraryModel(hosts: hosts)
        let model = ServerMetricsModel(
            hosts: library, preferences: ReviewMetricsPreferences(),
            makeSampler: { preconditionFailure("UI review must not start a remote operation") })
        model.suspend()
        let app = AppModel(hosts: library, proAccess: .testing(status: .free), serverMetrics: model)
        defer { app.shutdownForTermination() }
        let navigation = WindowModel()
        let server = ServerMetric(selection: MetricsSelection(id: hosts[3].id), name: hosts[3].name)
        server.point = MetricsPoint(date: .now, cpu: 64, memory: 48)
        server.hostAccessError = .lockedHost(hosts[3].id)
        #expect(library.isLocked(hosts[3]))
        #expect(!library.isLocked(hosts[0]))

        let content = VStack(alignment: .leading, spacing: 24) {
            Text(AppStrings.Vault.hosts).font(.title2.bold())
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach(hosts) { host in
                    HostCard(
                        host: host, isSelected: false, select: {}, extendSelection: {},
                        actionHosts: [host], requestDelete: {})
                }
            }
            Text(AppStrings.Navigation.metrics).font(.title2.bold())
            ServerMetricsCard(
                server: server, model: model,
                inspect: {}, upgrade: { app.proAccess.presentPaywall() }, openTerminal: {}
            )
            .frame(width: 364)
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 800, height: 490)
        .background(TermindColor.windowSurface)
        .environment(app)
        .environment(navigation)
        .environment(\.locale, Locale(identifier: language))
        .environment(\.colorScheme, .light)
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 490),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Termind Host Access Review - \(language)"
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 800, height: 490))
        window.center()
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        print("TERMIND_HOST_ACCESS_REVIEW|\(window.windowNumber)|\(language)")
        fflush(nil)
        try await Task.sleep(for: .seconds(4))
    }
}

@MainActor
private final class ReviewMetricsPreferences: MetricsConfigurationStoring {
    func load() -> [MetricsSelection] { [] }
    func save(_: [MetricsSelection]) {}
}
