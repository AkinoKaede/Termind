import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@Suite(.serialized) @MainActor
struct SFTPSettingsIntegrationTests {
    @Test func connectionsCategoryUsesTheConnectSymbol() {
        #expect(SettingsCategory.connections.symbol == MenuSymbol.connect)
    }

    @Test func localAndRemoteChangesReachTheQueueWithoutOpeningSettings() {
        let settings = SFTPSettingsModel()
        let app = AppModel(hosts: HostLibraryModel(), sftpSettings: settings)
        defer { app.shutdownForTermination() }
        #expect(app.sftpTransfers.globalLimit == 30)
        #expect(app.sftpTransfers.perHostLimit == 10)
        #expect(app.sftpTransfers.strategy == .smart)
        #expect(settings.set(100, for: \.globalLimit))
        #expect(settings.set(50, for: \.perHostLimit))
        #expect(settings.setStrategy(.connectionsPreferred))
        #expect(app.sftpTransfers.globalLimit == 100)
        #expect(app.sftpTransfers.perHostLimit == 50)
        #expect(app.sftpTransfers.strategy == .connectionsPreferred)
        settings.applyRemoteSnapshot(SFTPPreferences(globalLimit: 3, perHostLimit: 2, strategy: .channelsOnly))
        #expect(app.sftpTransfers.globalLimit == 3)
        #expect(app.sftpTransfers.perHostLimit == 2)
        #expect(app.sftpTransfers.strategy == .channelsOnly)
    }

    @Test(.requiresVisibleWindow, arguments: ["en", "zh-Hans", "zh-Hant"])
    func sftpSettingsRenderTheDefaultsAndMaximumLimits(language: String) async throws {
        let app = AppModel(hosts: HostLibraryModel())
        let model = WindowModel(workspaces: [])
        model.openSettings(route: .category(.connections))
        defer { app.shutdownForTermination() }
        let view = SettingsPageView().environment(app).environment(model)
            .environment(\.locale, Locale(identifier: language))
            .frame(width: 640, height: 520)
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        for value in [SFTPPreferences(), SFTPPreferences(globalLimit: 100, perHostLimit: 50)] {
            app.sftpSettings.applyRemoteSnapshot(value)
            try await Task.sleep(for: .milliseconds(300))
            controller.view.layoutSubtreeIfNeeded()
            let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            Attachment.record(data, named: "sftp-settings-\(language)-\(value.globalLimit).png")
            #expect(data.count > 5_000)
        }
    }
}
