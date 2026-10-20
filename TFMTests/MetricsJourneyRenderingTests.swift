// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct MetricsJourneyRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func metricsAuthenticateInsideTheirJourneyWithoutOpeningAnExternalWindow(_ language: String) async throws {
        let identity = Identity(name: "Deploy", username: "deploy")
        let host = Host(name: "Production Gateway", host: "gateway.example.invalid", identityID: identity.id)
        let library = HostLibraryModel(hosts: [host], identities: [identity])
        try library.upsert(identity, passwordUpdate: .replace("test-only"))
        let sampler = DesktopJourneyMetricsSampler()
        let model = ServerMetricsModel(
            hosts: library, preferences: DesktopJourneyPreferences(), makeSampler: { sampler })
        let app = AppModel(hosts: library, serverMetrics: model)
        await sampler.setFallback(app.externalAuthentication.keyboardInteractive)
        let navigation = WindowModel()
        navigation.selectedDestination = .metrics
        navigation.metricsModel = model
        let controller = NSHostingController(
            rootView: ServerMetricsView().environment(app).environment(navigation)
                .environment(\.locale, Locale(identifier: language)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 740),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            model.shutdown()
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        #expect(model.add(host))
        let server = try #require(model.servers.first)
        for _ in 0..<400 where server.keyboardAuthentication.current == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let challenge = try #require(server.keyboardAuthentication.current)
        #expect(navigation.metricsHostID == nil)
        #expect(app.externalAuthentication.pending.isEmpty)
        #expect(app.externalAuthentication.presentationRevision == 0)
        navigation.metricsHostID = host.id
        for width in [600.0, 1000.0] {
            window.setContentSize(NSSize(width: width, height: 740))
            try await Task.sleep(for: .milliseconds(300))
            controller.view.layoutSubtreeIfNeeded()
            let fields = editableFields(in: controller.view)
            #expect(fields.count == 2)
            #expect(fields.filter { $0 is NSSecureTextField }.count == 1)
            #expect(window.attachedSheet == nil)
            #expect(!navigation.showsCompactMetricsDetail)
            try capture(controller.view, name: "macos-metrics-journey-\(language)-\(Int(width))")
        }
        navigation.metricsHostID = nil
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.keyboardAuthentication.current?.id == challenge.id)
        navigation.metricsHostID = host.id
        try await Task.sleep(for: .milliseconds(300))
        window.makeKeyAndOrderFront(nil)
        let escape = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.sendEvent(escape)
        for _ in 0..<100 where server.selection.enabled { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!server.selection.enabled)
        #expect(navigation.metricsHostID == nil)
        #expect(server.keyboardAuthentication.pending.isEmpty)
        #expect(app.externalAuthentication.pending.isEmpty)
        #expect(await sampler.connections == 1)
    }

    private func editableFields(in view: NSView) -> [NSTextField] {
        if let field = view as? NSTextField, field.isEditable { return [field] }
        return view.subviews.flatMap { editableFields(in: $0) }
    }

    private func capture(_ view: NSView, name: String) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(data, named: "\(name).png")
        let directory = FileManager.default.temporaryDirectory.appending(path: "termind-metrics-journey")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "\(name).png"))
    }
}

@MainActor private final class DesktopJourneyPreferences: MetricsConfigurationStoring {
    func load() -> [MetricsSelection] { [] }
    func save(_ selections: [MetricsSelection]) {}
}

private actor DesktopJourneyMetricsSampler: MetricsSampling {
    var connections = 0
    private var fallback: SSHKeyboardInteractiveHandler?
    func setFallback(_ handler: @escaping SSHKeyboardInteractiveHandler) { fallback = handler }
    func connect(_ configuration: SSHConnectionConfiguration) async throws { throw CancellationError() }
    func connect(_ request: SSHConnectionRequest) async throws {
        connections += 1
        // Match the live exec Channel's fallback path: Metrics must always override it.
        let handler = try #require(request.withKeyboardInteractiveFallback(fallback).keyboardInteractive)
        _ = try await handler(
            SSHKeyboardInteractiveChallenge(
                connectionID: UUID(), hostID: request.configuration.hostID,
                hostname: request.configuration.host, port: request.configuration.port,
                username: request.configuration.username, round: 1, name: "PAM",
                instruction: "Enter your account and verification code.",
                prompts: [.init(text: "Account", echo: true), .init(text: "Verification code", echo: false)]))
    }
    func sample() async throws -> MetricsSample {
        .init(uptime: 1, cpu: [10, 0, 10, 80], memoryUsed: 50, memoryTotal: 100)
    }
    func gpu() async throws -> NvidiaSnapshot? { nil }
    func disconnect() async {}
}
