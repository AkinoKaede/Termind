import AppKit
import RevenueCat
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind
@testable import TermindInfrastructure

@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["TERMIND_HOST_ACCESS_FLOW_REVIEW"] == "1"),
    .serialized)
@MainActor
struct HostAccessFlowUIReviewTests {
    @Test(.requiresVisibleWindow)
    func reviewNativeHostAccessFlows() async throws {
        let metricsOnly = ProcessInfo.processInfo.environment["TERMIND_HOST_ACCESS_METRICS_REVIEW_ONLY"] == "1"
        NSApp.unhideWithoutActivation()
        let configuration = try #require(RevenueCatConfiguration.bundled())
        if !Purchases.isConfigured {
            Purchases.configure(
                with: Configuration.builder(withAPIKey: configuration.apiKey)
                    .with(automaticDeviceIdentifierCollectionEnabled: false)
                    .with(preferredUILocaleOverride: "en"))
        }
        let service = ReviewAccessPurchaseService()
        let pro = ProAccessController(purchaseService: service, observeUpdates: false)
        await pro.refresh()
        var hosts = ["Production", "Staging", "Database", "Backup"].enumerated().map { index, name in
            TermindDomain.Host(
                name: name, host: "\(name.lowercased()).example.invalid",
                createdAt: Date(timeIntervalSince1970: Double(index)))
        }
        hosts[3].wakeOnLAN.macAddress = "02:11:22:33:44:55"
        let library = HostLibraryModel(hosts: hosts)
        let metrics = ServerMetricsModel(
            hosts: library, preferences: FlowReviewMetricsPreferences(),
            makeSampler: { preconditionFailure("UI review must not open a remote connection") })
        metrics.suspend()
        let app = AppModel(hosts: library, proAccess: pro, serverMetrics: metrics)
        defer { app.shutdownForTermination() }
        let navigation = WindowModel()
        navigation.openPage(.hosts)
        let controller = NSHostingController(
            rootView: RootView(window: navigation)
                .environment(app)
                .environment(\.locale, Locale(identifier: "en"))
                .environment(\.colorScheme, .light))
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1240, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1240, height: 820))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        try await settle(window)
        if !metricsOnly {
            try await capture("hosts", window: window)
            try showWakeMenu(host: hosts[3], app: app, navigation: navigation, controller: controller, window: window)
            #expect(pro.isPaywallPresented)
            try await Task.sleep(for: .seconds(5))
            try await capture("wake-paywall", window: window)
            pro.isPaywallPresented = false
            try await settle(window)
        }

        #expect(metrics.add(hosts[3]))
        let server = try #require(metrics.servers.first)
        server.point = MetricsPoint(date: .now, cpu: 64, memory: 48)
        metrics.reconcile()
        navigation.selectedDestination = .metrics
        try await capture("metrics", window: window)

        library.hostAccess.entitlement = .loading
        metrics.reconcile()
        try await capture("metrics-checking", window: window)
        library.hostAccess.entitlement = .verificationFailed
        metrics.reconcile()
        try await capture("metrics-verification-failed", window: window)
        if metricsOnly { return }
        library.hostAccess.entitlement = .free

        metrics.remove(hosts[3].id)
        library.projectHostDeletion(hosts[3].id)
        navigation.openHostEditor(host: nil)
        try await settle(window)
        let fields = descendants(controller.view).compactMap { $0 as? NSTextField }
        print("HOST_REVIEW_FIELDS \(fields.map { ($0.placeholderString ?? "-", $0.stringValue) })")
        let address = try #require(
            fields.first {
                $0.placeholderString == "IP address or hostname" || ($0.isEditable && $0.accessibilityLabel() == "Host")
            }, "The actual host address field must be available")
        #expect(window.makeFirstResponder(address))
        let editor = try #require(address.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("backup.example.invalid", replacementRange: editor.selectedRange())
        window.makeFirstResponder(nil)
        try await settle(window)
        try await capture("new-host", window: window)

        service.delay = .seconds(8)
        library.hostAccess.entitlement = .loading
        try pressSave(window)
        try await capture("save-checking", window: window)
        for _ in 0..<100 {
            if pro.isPaywallPresented { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(pro.isPaywallPresented)
        #expect(library.hosts.count == 3)
        try await Task.sleep(for: .seconds(5))
        #expect(window.attachedSheet != nil)
        try await capture("save-paywall", window: window)

        pro.isPaywallPresented = false
        try await settle(window)
        service.delay = .zero
        library.hostAccess.entitlement = .verificationFailed
        try pressSave(window)
        try await capture("save-verification-failed", window: window)
        #expect(library.hosts.count == 3)

        library.hostAccess.entitlement = .free
        navigation.openVaultWork(.sshImport(knownHostsOnly: false), on: .hosts)
        try await settle(window)
        let directory = FileManager.default.temporaryDirectory.appending(path: "HostReview-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        Host Backup
            HostName backup.example.invalid
            User deploy
        """.write(to: directory.appending(path: "config"), atomically: true, encoding: .utf8)
        let receiver = try #require(
            descendants(controller.view).compactMap { $0 as? FileURLDropNSView }
                .last { $0.isEnabled && $0.acceptedKinds == [.files] })
        #expect(receiver.receivePayload(NativeDropPayload(fileURLs: [directory])))
        try await Task.sleep(for: .seconds(2))
        try await capture("import-selection", window: window)
        let importButton =
            accessibilityButton("Import", in: controller.view)
            ?? accessibilityButton("Import", in: window)
            ?? descendants(controller.view).lazy.compactMap { accessibilityButton("Import", in: $0) }.first
        if let importButton {
            #expect(importButton.accessibilityPerformPress())
        } else {
            // SwiftUI may defer its AX tree until an external accessibility client attaches.
            // This opt-in review also accepts a real click on the visible Import button.
            print("TERMIND_ACCESS_IMPORT_READY")
            fflush(nil)
            for _ in 0..<900 {
                if pro.isPaywallPresented { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        try await Task.sleep(for: .seconds(4))
        #expect(pro.isPaywallPresented)
        #expect(library.hosts.count == 3)
        #expect(window.attachedSheet != nil)
        try await capture("import-paywall", window: window)
        pro.isPaywallPresented = false
        try await capture("import-retained", window: window)

        library.hostAccess.entitlement = .unrestrictedForTesting
        library.upsert(hosts[3])
        library.hostAccess.entitlement = .verificationFailed
        navigation.openPage(.hosts)
        #expect(app.open(hosts[3], as: .sshSession, in: navigation) == nil)
        #expect(navigation.hostAccessError == String(localized: AppStrings.Pro.accessVerificationFailed))
        try await capture("connection-verification-failed", window: window)
    }

    private func pressSave(_ window: NSWindow) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(window.performKeyEquivalent(with: event))
    }

    private func settle(_ window: NSWindow) async throws {
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func capture(_ name: String, window: NSWindow) async throws {
        try await settle(window)
        markCapture(name, window: window.attachedSheet ?? window)
        try await Task.sleep(for: .seconds(2))
    }

    private func markCapture(_ name: String, window: NSWindow) {
        let screenTop = NSScreen.screens.first?.frame.maxY ?? window.frame.maxY
        let frame = window.frame
        let rect = "\(Int(frame.minX)),\(Int(screenTop - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
        print("TERMIND_ACCESS_FLOW|\(name)|\(window.windowNumber)|\(rect)")
        fflush(nil)
    }

    private func showWakeMenu(
        host: TermindDomain.Host, app: AppModel, navigation: WindowModel,
        controller: NSViewController, window: NSWindow
    ) throws {
        let menu = NativeMenuEntry.menu(
            HostMenuEntries.entries(for: host, app: app, window: navigation, includesDuplicate: true))
        let wake = try #require(menu.items.first { $0.title == "Wake" })
        #expect(app.hostLibrary.isLocked(host))
        #expect(wake.isEnabled)
        let menuController = FlowReviewMenuController(menu: menu)
        let captureTimer = Timer(timeInterval: 0.5, repeats: false) { _ in
            MainActor.assumeIsolated { markCapture("wake-upgrade", window: window) }
        }
        let dismissTimer = Timer(timeInterval: 2.5, repeats: false) { _ in
            MainActor.assumeIsolated { menuController.cancel() }
        }
        RunLoop.main.add(captureTimer, forMode: .eventTracking)
        RunLoop.main.add(dismissTimer, forMode: .eventTracking)
        menu.popUp(positioning: nil, at: CGPoint(x: 850, y: 420), in: controller.view)
        menu.performActionForItem(at: menu.index(of: wake))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func accessibilityButton(_ title: String, in element: Any) -> (any NSAccessibilityProtocol)? {
        guard let accessible = element as? any NSAccessibilityProtocol else { return nil }
        if accessible.accessibilityRole() == .button,
            accessible.accessibilityLabel() == title || accessible.accessibilityTitle() == title
        {
            return accessible
        }
        for child in accessible.accessibilityChildren() ?? [] {
            if let button = accessibilityButton(title, in: child) { return button }
        }
        return nil
    }
}

@MainActor
private final class FlowReviewMenuController {
    let menu: NSMenu

    init(menu: NSMenu) {
        self.menu = menu
    }

    func cancel() {
        menu.cancelTracking()
    }
}

@MainActor
private final class ReviewAccessPurchaseService: ProPurchaseService {
    let updates = AsyncStream<EntitlementStatus> { $0.finish() }
    var delay = Duration.zero
    func currentStatus() async throws -> EntitlementStatus {
        if delay > .zero { try await Task.sleep(for: delay) }
        return .free
    }
}

@MainActor
private final class FlowReviewMetricsPreferences: MetricsConfigurationStoring {
    func load() -> [MetricsSelection] { [] }
    func save(_: [MetricsSelection]) {}
}
