import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite(.serialized) @MainActor
struct PortForwardingRenderingTests {
    @Test(arguments: [false, true])
    func saveClosesTheEditorOnlyAfterPersistenceSucceeds(_ fails: Bool) async throws {
        let host = Host(name: "Server", host: "server.example.invalid")
        let rule = PortForwardingRule(hostID: host.id, label: "Database")
        let snapshot = VaultSnapshot(hosts: [host], portForwardings: [rule])
        let library = HostLibraryModel(
            hosts: [host], portForwardings: [rule],
            persistence: fails ? RejectingForwardingSave(snapshot: snapshot) : nil)
        let app = AppModel(hosts: library)
        let navigation = WindowModel()
        navigation.openVaultWork(.forwardingEditor(rule.id), on: .portForwarding)
        let controller = NSHostingController(
            rootView: VaultWorkspaceView().environment(app).environment(navigation))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 740),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.sizingOptions = []
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            app.shutdownForTermination()
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(300))
        let name = try #require(
            descendants(in: controller.view).compactMap { $0 as? NSTextField }
                .first { $0.isEditable && $0.stringValue == rule.label })
        name.stringValue = "Updated Database"
        name.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: name))
        await Task.yield()
        let save = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(window.performKeyEquivalent(with: save))
        if fails {
            #expect(navigation.vaultWorkRoute == .forwardingEditor(rule.id))
            #expect(app.forwardings.portForwarding(rule.id)?.label == "Database")
            #expect(name.stringValue == "Updated Database")
            #expect(name.window === window)
        } else {
            #expect(navigation.vaultWorkRoute == nil)
            #expect(navigation.vaultSelection(for: .portForwarding) == [.forwarding(rule.id)])
            #expect(app.forwardings.portForwarding(rule.id)?.label == "Updated Database")
            try await waitUntil(in: controller.view) { name.window == nil }
            #expect(name.window == nil)
        }
        #expect(app.forwarding.state(for: rule.id) == .stopped)
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func cardsAndJourneyKeepTheirStateAcrossWindowSizes(_ language: String) async throws {
        let host = Host(name: "Production", host: "server.example.invalid")
        let rules = [
            PortForwardingRule(hostID: host.id, label: "Database", colorTag: .teal),
            PortForwardingRule(hostID: host.id, kind: .remote, bindPort: 9090, label: "Preview", colorTag: .orange),
            PortForwardingRule(hostID: host.id, kind: .dynamic, bindPort: 1080, label: "SOCKS5"),
            PortForwardingRule(hostID: host.id, bindPort: 15432),
        ]
        let library = HostLibraryModel(hosts: [host], portForwardings: rules)
        let app = AppModel(hosts: library)
        let navigation = WindowModel()
        navigation.openPage(.portForwarding)
        let controller = NSHostingController(
            rootView: VaultWorkspaceView().environment(app).environment(navigation)
                .environment(\.locale, Locale(identifier: language)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 740),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 960, height: 740))
        controller.view.frame = NSRect(x: 0, y: 0, width: 960, height: 740)
        window.makeKeyAndOrderFront(nil)
        defer {
            app.shutdownForTermination()
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutSubtreeIfNeeded()
        try capture(controller.view, name: "macos-forwarding-cards-\(language)")
        let marquee = try #require(
            descendants(in: controller.view).first { String(describing: type(of: $0)) == "MarqueeInputView" })
        marquee.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 2, y: 2), in: marquee))
        marquee.mouseDragged(
            with: try mouseEvent(
                .leftMouseDragged, at: CGPoint(x: marquee.bounds.maxX - 2, y: marquee.bounds.maxY - 2), in: marquee))
        marquee.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: 2, y: 2), in: marquee))
        #expect(Set(navigation.vaultSelection(for: .portForwarding).compactMap(\.forwardingID)) == Set(rules.map(\.id)))
        try await Task.sleep(for: .milliseconds(100))
        try capture(controller.view, name: "macos-forwarding-selected-\(language)")
        marquee.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 2, y: 2), in: marquee))
        marquee.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: 2, y: 2), in: marquee))
        #expect(navigation.vaultSelection(for: .portForwarding).isEmpty)
        navigation.openVaultWork(.forwardingEditor(rules[0].id), on: .portForwarding)
        try await Task.sleep(for: .milliseconds(300))
        try capture(controller.view, name: "macos-forwarding-editor-\(language)")
        navigation.closeVaultWork()
        app.forwarding.start(rules[0].id)
        for _ in 0..<400 where app.forwarding.connection(for: rules[0].id)?.authenticationPrompt == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let context = try #require(app.forwarding.connection(for: rules[0].id))
        let prompt = try #require(context.authenticationPrompt)
        navigation.openVaultWork(.forwardingEditor(rules[0].id), on: .portForwarding)
        var passwordField: NSSecureTextField?
        for width in [960.0, 360.0, 640.0, 641.0, 681.0, 960.0] {
            window.setContentSize(NSSize(width: width, height: 440))
            controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 440)
            try await Task.sleep(for: .milliseconds(300))
            controller.view.layoutSubtreeIfNeeded()
            #expect(context.authenticationPrompt?.id == prompt.id)
            #expect(app.forwarding.connection(for: rules[0].id) === context)
            #expect(window.attachedSheet == nil)
            #expect(app.externalAuthentication.pending.isEmpty)
            let field = try #require(descendants(in: controller.view).compactMap { $0 as? NSSecureTextField }.first)
            if let passwordField {
                #expect(field === passwordField)
                #expect(field.stringValue == "Unsaved test credential")
            } else {
                passwordField = field
                field.stringValue = "Unsaved test credential"
                field.delegate?.controlTextDidChange?(
                    Notification(name: NSControl.textDidChangeNotification, object: field))
            }
            let scroll = try #require(field.enclosingScrollView)
            let document = try #require(scroll.documentView)
            #expect(document.frame.height > scroll.contentView.bounds.height)
            scroll.contentView.scroll(
                to: CGPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(30))
            try capture(controller.view, name: "macos-forwarding-journey-\(language)-\(Int(width))")
        }
        navigation.closeVaultWork()
        navigation.openPage(.snippets)
        #expect(context.authenticationPrompt?.id == prompt.id)
        navigation.openVaultWork(.forwardingEditor(rules[0].id), on: .portForwarding)
        #expect(app.forwarding.connection(for: rules[0].id) === context)
        for _ in 0..<3 {
            navigation.closeVaultWork()
            await Task.yield()
            navigation.openVaultWork(.forwardingEditor(rules[0].id), on: .portForwarding)
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(context.authenticationPrompt?.id == prompt.id)
        #expect(app.forwarding.connection(for: rules[0].id) === context)
        app.forwarding.stop(rules[0].id)
        #expect(context.authenticationPrompt == nil)
        #expect(app.forwarding.state(for: rules[0].id) == .stopped)
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func embeddedJourneyDecisionsAndLogsFitShortNarrowColumns(_ language: String) async throws {
        let host = Host(name: "Production Database Gateway with a Long Name", host: "gateway.example.invalid")
        let jump = Host(name: "Jump Host", host: "jump.example.invalid")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host, jump]))
        defer { app.shutdownForTermination() }

        for state in ["host-key", "keyboard", "failure", "logs"] {
            let journey = ConnectionJourney()
            journey.begin(host: host, route: [jump, host], purpose: .portForwarding, username: "deploy")
            let queue = SSHKeyboardInteractiveQueue()
            var request: Task<[String], any Error>?
            var hostKey: SSHHostKeyPrompt?
            var actions = 0
            let challenge = SSHKeyboardInteractiveChallenge(
                connectionID: UUID(), hostID: host.id, hostname: host.host, port: 22,
                username: "deploy", round: 1, name: "PAM", instruction: "Enter your account and verification code.",
                prompts: [.init(text: "Account", echo: true), .init(text: "Verification code", echo: false)])
            switch state {
            case "host-key":
                let observation = SSHHostKeyObservation(
                    hostname: host.host, port: 22, algorithm: .ed25519,
                    fingerprint: "SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG")
                hostKey = SSHHostKeyPrompt(observation: observation, kind: .firstUse)
                journey.waitForHostKey(at: host.id, fingerprint: observation.fingerprint)
            case "keyboard":
                journey.waitForAuthentication(at: host.id)
                request = Task { try await queue.request(challenge) }
                for _ in 0..<100 where queue.current == nil { await Task.yield() }
                #expect(queue.current?.id == challenge.id)
            case "failure":
                journey.fail("The forwarding listener could not bind to 127.0.0.1:8080 because the port is in use.")
            default:
                journey.log(
                    endpoint: host.name, message: "Negotiating encryption and authenticating the forwarding route.")
                journey.showsLogs = true
            }
            let controller = NSHostingController(
                rootView: VaultDetailScaffold(title: "Port Forwarding", symbol: "arrow.left.arrow.right", close: {}) {
                    ConnectionJourneyView(
                        journey: journey, hostKey: hostKey,
                        submitAuthentication: { _, _, _, _, _, _ in actions += 1 },
                        continueHostKey: { _ in actions += 1 }, trustHostKey: { _ in actions += 1 },
                        denyHostKey: { actions += 1 }, retry: { actions += 1 }, cancel: { actions += 1 },
                        keyboardAuthentication: queue, isEmbedded: true)
                } footer: {
                    HStack {
                        Spacer()
                        Button("Close") {}
                    }.padding(12)
                }
                .environment(app)
                .environment(\.locale, Locale(identifier: language)))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 440),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            controller.sizingOptions = []
            window.contentViewController = controller
            window.makeKeyAndOrderFront(nil)
            defer {
                queue.cancel(challenge.id)
                request?.cancel()
                window.orderOut(nil)
                window.contentViewController = nil
                window.close()
            }
            var fields: [NSTextField]?
            for width in [400.0, 360.0, 400.0] {
                window.setContentSize(NSSize(width: width, height: 440))
                controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 440)
                try await Task.sleep(for: .milliseconds(100))
                controller.view.layoutSubtreeIfNeeded()
                #expect(abs(controller.view.bounds.width - width) <= 1)
                let scroll = try #require(descendants(in: controller.view).compactMap { $0 as? NSScrollView }.first)
                #expect(abs(scroll.bounds.width - width) <= 1)
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                if state == "keyboard" {
                    let currentFields = descendants(in: controller.view).compactMap { $0 as? NSTextField }.filter(
                        \.isEditable)
                    #expect(currentFields.count == 2)
                    if let fields {
                        #expect(zip(fields, currentFields).allSatisfy { $0 === $1 })
                    } else {
                        fields = currentFields
                    }
                    #expect(queue.current?.id == challenge.id)
                }
                try capture(controller.view, name: "macos-forwarding-\(state)-\(language)-\(Int(width))-top")
                if let document = scroll.documentView {
                    scroll.contentView.scroll(
                        to: CGPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try await Task.sleep(for: .milliseconds(30))
                    try capture(controller.view, name: "macos-forwarding-\(state)-\(language)-\(Int(width))-bottom")
                }
                #expect(actions == 0)
            }
        }
    }

    @Test(arguments: [false, true])
    func closingJourneyRetainsItsExitViewButDisablesAuthentication(_ reduceMotion: Bool) async throws {
        let host = Host(name: "Server", host: "server.example.invalid")
        let rule = PortForwardingRule(hostID: host.id)
        let app = AppModel(hosts: HostLibraryModel(hosts: [host], portForwardings: [rule]))
        let navigation = WindowModel()
        navigation.openPage(.portForwarding)
        let controller = NSHostingController(
            rootView: VaultWorkspaceContent(reduceMotion: reduceMotion).environment(app).environment(navigation))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.sizingOptions = []
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            app.shutdownForTermination()
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        app.forwarding.start(rule.id)
        for _ in 0..<400 where app.forwarding.connection(for: rule.id)?.authenticationPrompt == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let context = try #require(app.forwarding.connection(for: rule.id))
        let prompt = try #require(context.authenticationPrompt)
        navigation.openVaultWork(.forwardingEditor(rule.id), on: .portForwarding)
        try await Task.sleep(for: .milliseconds(300))
        #expect(descendants(in: controller.view).contains { $0 is NSSecureTextField })
        navigation.closeVaultWork()
        try await Task.sleep(for: .milliseconds(40))
        controller.view.layoutSubtreeIfNeeded()
        let exitingFields = descendants(in: controller.view).compactMap { $0 as? NSSecureTextField }
        if reduceMotion {
            #expect(exitingFields.isEmpty)
        } else {
            #expect(!exitingFields.isEmpty)
            #expect(exitingFields.allSatisfy { !$0.isEnabled })
        }
        try await waitUntil(in: controller.view) {
            !descendants(in: controller.view).contains { $0 is NSSecureTextField }
        }
        #expect(!descendants(in: controller.view).contains { $0 is NSSecureTextField })
        for _ in 0..<3 {
            navigation.openVaultWork(.forwardingEditor(rule.id), on: .portForwarding)
            try await waitUntil(in: controller.view) {
                descendants(in: controller.view).contains { ($0 as? NSSecureTextField)?.isEnabled == true }
            }
            navigation.closeVaultWork()
            await Task.yield()
        }
        navigation.openVaultWork(.forwardingEditor(rule.id), on: .portForwarding)
        try await waitUntil(in: controller.view) {
            descendants(in: controller.view).contains { ($0 as? NSSecureTextField)?.isEnabled == true }
        }
        #expect(context.authenticationPrompt?.id == prompt.id)
        #expect(app.forwarding.connection(for: rule.id) === context)
        #expect(app.forwarding.state(for: rule.id) == .awaitingAuthentication)
        navigation.closeVaultWork()
        try await waitUntil(in: controller.view) {
            !descendants(in: controller.view).contains { $0 is NSSecureTextField }
        }
    }

    private func descendants(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
    }

    private func waitUntil(in view: NSView, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            view.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "The native view did not finish updating within two seconds.")
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func capture(_ view: NSView, name: String) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(data, named: "\(name).png")
        let directory = FileManager.default.temporaryDirectory.appending(path: "termind-forwarding-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "\(name).png"))
    }
}

@MainActor private final class RejectingForwardingSave: VaultPersisting {
    let snapshot: VaultSnapshot
    init(snapshot: VaultSnapshot) { self.snapshot = snapshot }
    func load() throws -> VaultSnapshot { snapshot }
    func save(_ snapshot: VaultSnapshot) throws -> VaultMutationSet { throw CocoaError(.fileWriteNoPermission) }
    func saveIdentityLastUsedAt(_ updates: [Identity.ID: Date]) throws {}
    func applyRemote(_ envelopes: [VaultEnvelope]) throws -> VaultRemoteApplyResult {
        throw CocoaError(.fileWriteNoPermission)
    }
}
