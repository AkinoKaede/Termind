import Foundation
import GhosttyTerminal
import SwiftUI
import TermindDomain
import Testing
import UIKit

import struct TermindDomain.Host

@testable import TermindIOS

/// Opt-in native rendering coverage for icon labels in every supported language and appearance.
/// Set TERMIND_ICON_SCREENSHOTS to en, zh-Hans, or zh-Hant in the test runner environment.
@Suite(.serialized) @MainActor
struct MobileIconRenderingTests {
    @Test func terminalKeyboardKeepsItsCompactHeight() {
        #expect(UIImage(systemName: "play.rectangle") != nil)
        #expect(UIImage(systemName: "doc.on.clipboard") != nil)
        #expect(MobileTerminalKeyboard.barHeight == 44)
        for width in [CGFloat(320), 390, 430] {
            for dynamicTypeSize in [DynamicTypeSize.large, .accessibility3] {
                let controller = UIHostingController(
                    rootView: MobileTerminalKeyboard(state: TerminalViewState(), paste: {})
                        .environment(\.dynamicTypeSize, dynamicTypeSize))
                let size = controller.sizeThatFits(in: CGSize(width: width, height: 800))
                #expect(abs(size.height - 44) < 0.5)
            }
        }
    }

    @Test func renderIconNavigationAndForms() async throws {
        guard let language = ProcessInfo.processInfo.environment["TERMIND_ICON_SCREENSHOTS"] else { return }
        let app = try MobileAppModel(inMemory: true)
        let forwardingHost = Host(name: "Example", host: "example.invalid")
        let forwardingRule = PortForwardingRule(hostID: forwardingHost.id, label: "Web")
        app.library.upsert(forwardingHost)
        #expect(app.library.upsert(forwardingRule))
        let proxyHost = Host(
            name: "Proxied", host: "proxied.example.invalid",
            proxy: HostProxy(kind: .socks5, hostname: "proxy.example.invalid", port: 1080))
        let snippetApp = try MobileAppModel(inMemory: true)
        let snippetHost = Host(name: "Production", host: "production.example.invalid")
        let snippetPackage = SnippetPackage(name: "Operations")
        let snippetSubpackage = SnippetPackage(name: "Linux", parentID: snippetPackage.id)
        let snippet = Snippet(
            title: "Disk usage", body: "df -h\ndu -sh /var/log", packageID: snippetSubpackage.id,
            targetHostIDs: [snippetHost.id])
        snippetApp.library.upsert(snippetHost)
        snippetApp.snippets.upsert(snippetPackage)
        snippetApp.snippets.upsert(snippetSubpackage)
        snippetApp.snippets.upsert(snippet)
        let connectionApp = try MobileAppModel(inMemory: true)
        connectionApp.library.upsert(Host(name: "Production", host: "production.example.invalid"))
        let locale = Locale(identifier: language)
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try await capture("vault-\(suffix)", language: language, scheme: scheme) {
                NavigationStack {
                    MobileVaultView(
                        app: app, editingHost: .constant(nil), activateHost: { _ in },
                        open: { _, _ in })
                }.environment(\.locale, locale)
            }
            try await capture("snippets-\(suffix)", language: language, scheme: scheme) {
                NavigationStack { MobileSnippetsView(app: snippetApp) }.environment(\.locale, locale)
            }
            try await capture("snippet-detail-\(suffix)", language: language, scheme: scheme) {
                NavigationStack {
                    MobileSnippetDetailView(
                        app: snippetApp, snippetID: snippet.id, execute: { _ in },
                        executeOnHosts: { _ in }, edit: {}, duplicate: { _ in }, delete: {})
                }
                .environment(\.locale, locale)
            }
            try await capture("snippet-editor-\(suffix)", language: language, scheme: scheme) {
                MobileSnippetEditor(app: snippetApp, snippet: snippet, packageID: nil) { _ in }
                    .environment(\.locale, locale)
            }
            try await capture("snippet-targets-\(suffix)", language: language, scheme: scheme) {
                MobileSnippetHostPicker(
                    app: snippetApp, selected: [snippetHost.id], title: "Add Hosts",
                    actionTitle: "Done", requiresSelection: false, save: { _ in }
                )
                .environment(\.locale, locale)
            }
            try await capture("snippet-execution-targets-\(suffix)", language: language, scheme: scheme) {
                MobileSnippetHostPicker(
                    app: snippetApp, selected: [], title: "Execute on Hosts",
                    actionTitle: "Execute", requiresSelection: true, save: { _ in }
                )
                .environment(\.locale, locale)
            }
            try await capture("settings-\(suffix)", language: language, scheme: scheme) {
                NavigationStack { MobileSettingsView(app: app) }.environment(\.locale, locale)
            }
            try await capture("skills-\(suffix)", language: language, scheme: scheme) {
                NavigationStack { MobileSkillSettings(skills: app.skills) }.environment(\.locale, locale)
            }
            try await capture("context-menu-card-\(suffix)", language: language, scheme: scheme) {
                NavigationStack {
                    MobileActionCard(action: {}) {
                        Text("Example")
                    } actions: {
                        Button("Delete", systemImage: "trash", role: .destructive) {}
                    }
                    .padding()
                    .navigationTitle("Context Menu")
                }
                .environment(\.locale, locale)
            }
            try await capture("connection-picker-\(suffix)", language: language, scheme: scheme) {
                NavigationStack {
                    MobileConnectionPicker(
                        library: connectionApp.library, connect: { _, _ in }, cancel: {})
                }
                .environment(\.locale, locale)
            }
            try await capture("connection-picker-empty-\(suffix)", language: language, scheme: scheme) {
                NavigationStack {
                    MobileConnectionPicker(library: app.library, connect: { _, _ in }, cancel: {})
                }
                .environment(\.locale, locale)
            }
            try await capture("metrics-host-picker-\(suffix)", language: language, scheme: scheme) {
                NavigationStack {
                    MobileHostPicker(
                        library: connectionApp.library,
                        title: "Add Server",
                        emptyDescription: "Add a saved Linux server to start monitoring.",
                        cancel: {},
                        select: { _ in })
                }
                .environment(\.locale, locale)
            }
            try await capture("sftp-settings-\(suffix)", language: language, scheme: scheme) {
                NavigationStack { MobileSFTPSettingsView(transfers: app.transfers) }.environment(\.locale, locale)
            }
            try await capture("editor-\(suffix)", language: language, scheme: scheme) {
                MobileHostEditor(app: app, host: Host(name: "Example", host: "example.invalid"))
                    .environment(\.locale, locale)
            }
            try await capture("editor-proxy-\(suffix)", language: language, scheme: scheme) {
                MobileHostEditor(app: app, host: proxyHost)
                    .environment(\.locale, locale)
            }
            try await capture("forwarding-editor-\(suffix)", language: language, scheme: scheme) {
                MobileForwardingEditor(
                    app: app, rule: forwardingRule, isNew: false
                )
                .environment(\.locale, locale)
            }
            try await capture("add-\(suffix)", language: language, scheme: scheme) {
                MobileAddModelSheet(existing: [], add: { _ in }).environment(\.locale, locale)
            }
            try await capture("terminal-keyboard-\(suffix)", language: language, scheme: scheme) {
                VStack(spacing: 0) {
                    Spacer()
                    MobileTerminalKeyboard(state: TerminalViewState(), paste: {})
                }
                .environment(\.locale, locale)
            }
            try await capture("terminal-keyboard-selected-\(suffix)", language: language, scheme: scheme) {
                VStack(spacing: 0) {
                    Spacer()
                    MobileTerminalKeyboard(
                        state: TerminalViewState(),
                        initialShift: MobileTerminalShiftState(activation: .locked),
                        paste: {})
                }
                .environment(\.locale, locale)
            }
        }
        try await capture("settings-large-type", language: language, scheme: .light) {
            NavigationStack { MobileSettingsView(app: app) }
                .environment(\.locale, locale).environment(\.dynamicTypeSize, .accessibility3)
        }
        try await capture("snippets-large-type", language: language, scheme: .light) {
            NavigationStack { MobileSnippetsView(app: snippetApp) }
                .environment(\.locale, locale).environment(\.dynamicTypeSize, .accessibility3)
        }
        try await capture("connection-picker-large-type", language: language, scheme: .light) {
            NavigationStack {
                MobileConnectionPicker(library: connectionApp.library, connect: { _, _ in }, cancel: {})
            }
            .environment(\.locale, locale).environment(\.dynamicTypeSize, .accessibility3)
        }
        try await capture("sftp-settings-large-type", language: language, scheme: .light) {
            NavigationStack { MobileSFTPSettingsView(transfers: app.transfers) }
                .environment(\.locale, locale).environment(\.dynamicTypeSize, .accessibility3)
        }
        try await capture("editor-large-type", language: language, scheme: .light) {
            MobileHostEditor(app: app, host: Host(name: "Example", host: "example.invalid"))
                .environment(\.locale, locale).environment(\.dynamicTypeSize, .accessibility3)
        }
        try await capture("editor-disabled", language: language, scheme: .light) {
            MobileEditorSheet(title: String(localized: "Snippet"), isDirty: false, canSave: false, save: {}) {
                TextField("Title", text: .constant(""))
            }.environment(\.locale, locale)
        }
        try await capture("terminal-keyboard-large-type", language: language, scheme: .light) {
            VStack(spacing: 0) {
                Spacer()
                MobileTerminalKeyboard(state: TerminalViewState(), paste: {})
            }
            .environment(\.locale, locale).environment(\.dynamicTypeSize, .accessibility3)
        }
    }

    private func capture<V: View>(
        _ name: String, language: String, scheme: ColorScheme, @ViewBuilder view: () -> V
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: view().preferredColorScheme(scheme))
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        #expect(data.count > 10000)
        let directory = FileManager.default.temporaryDirectory.appending(path: "icon-screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let path = directory.appending(path: "\(device)-\(language)-\(name).png")
        try data.write(to: path)
        print("Icon snapshot: \(path.path)")
    }
}
