import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import Testing

@testable import TermindPresentation

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct TailscaleFormInteractionTests {
    @Test func theEntireAddressRowCopiesOnce() async throws {
        let address = "server-with-a-long-name.example.ts.net"
        var copies: [String] = []
        var rowFrame = CGRect.zero
        let fixture = TailscaleFormWindow(
            Form {
                Section {
                    TailscaleCopyField(label: AppStrings.Tailscale.magicDNS, value: address) { copies.append($0) }
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .named("tailscale.test"))
                        } action: {
                            rowFrame = $0
                        }
                }
            }.formStyle(.grouped))
        defer { fixture.close() }
        try await fixture.settle()
        #expect(rowFrame.width > 0 && rowFrame.height > 0)
        for (index, fraction) in [0.05, 0.65, 0.97].enumerated() {
            try fixture.click(NSPoint(x: rowFrame.minX + rowFrame.width * fraction, y: rowFrame.midY))
            try await fixture.settle()
            #expect(copies.count == index + 1)
            #expect(copies.allSatisfy { $0 == address })
        }
        try fixture.capture("tailscale-copy-feedback")
        try await Task.sleep(for: .milliseconds(1100))
        try fixture.click(NSPoint(x: rowFrame.midX, y: rowFrame.midY))
        try await Task.sleep(for: .milliseconds(1100))
        #expect(copies.count == 4)
        try fixture.capture("tailscale-copy-feedback-restarted")
        try await Task.sleep(for: .milliseconds(1100))
        try fixture.capture("tailscale-copy-feedback-restored")
    }

    @Test func hostnameKeepsItsWidthWhenTheNativeFieldTakesFocus() async throws {
        let model = TailscaleModel(
            library: HostLibraryModel(), store: InMemoryTailscaleLocalStore(),
            factory: { _, _, _, _ in throw TailscaleConfigurationError.unavailable }, profileStorage: .disabled,
            hostname: { "Kaede-MacBook-Pro" }, hasAccess: { true })
        let editor = TailscaleGroupEditor(model: model, group: nil)
        let fixture = TailscaleFormWindow(
            Form { Section { TailscaleLoginFields(editor: editor, requireAccess: { true }) } }.formStyle(.grouped))
        defer { fixture.close() }
        try await fixture.settle()
        func fields(_ view: NSView) -> [NSTextField] {
            ([view] + view.subviews.flatMap { descendants($0) }).compactMap { $0 as? NSTextField }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let root = try #require(fixture.window.contentView)
        let field = try #require(fields(root).first { $0.placeholderString == "Kaede-MacBook-Pro" })
        let width = field.frame.width
        #expect(fixture.window.makeFirstResponder(field))
        try await fixture.settle()
        #expect(abs(field.frame.width - width) < 1)
        #expect(field.frame.width > 80)
        try fixture.capture("tailscale-hostname-focused")
        await model.shutdown()
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func signedInEditorRendersSeparateUntitledAddressAndDetailsSections(language: String) async throws {
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net")
        let node = TailscaleFormPreviewNode(network: network)
        let model = TailscaleModel(
            library: HostLibraryModel(), store: InMemoryTailscaleLocalStore(),
            factory: { _, _, _, _ in node }, profileStorage: .disabled,
            hostname: { "MacBook" }, hasAccess: { true })
        let editor = TailscaleGroupEditor(model: model, group: nil)
        editor.draft.name = "Production"
        editor.setEnabled(true)
        editor.login(authKey: nil)
        for _ in 0..<100 where editor.pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        _ = try #require(editor.pending)
        editor.receiveLogin()
        let fixture = TailscaleFormWindow(
            Form {
                Section {
                    TextField(AppStrings.Common.name.swiftUIKey, text: .constant("Production"))
                }
                TailscaleGroupFields(editor: editor, requireAccess: { true }, copy: { _ in })
            }.formStyle(.grouped).environment(\.locale, Locale(identifier: language)))
        defer { fixture.close() }
        try await fixture.settle()
        try fixture.capture("tailscale-edit-connected-\(language)")
        editor.cancel()
        await model.shutdown()
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func addressAndInformationRowsRenderAtNarrowWidth(language: String) async throws {
        let fixture = TailscaleFormWindow(
            Form {
                Section(AppStrings.Tailscale.addresses.swiftUIKey) {
                    TailscaleCopyField(
                        label: AppStrings.Tailscale.magicDNS,
                        value: "production-server-with-a-long-hostname.example.ts.net", copy: { _ in })
                    TailscaleCopyField(
                        label: AppStrings.Tailscale.ipv6,
                        value: "fd7a:115c:a1e0:ab12:1234:5678:abcd:ef01", copy: { _ in })
                }
                TailscalePingSection(
                    pinging: .constant(true), result: .init(milliseconds: 12.4, route: .direct("100.64.0.2:41641")),
                    error: nil, history: [9, 14, 12.4], isAvailable: true)
                Section(AppStrings.Tailscale.details.swiftUIKey) {
                    TailscaleFormRow(label: AppStrings.Tailscale.keyExpiry, symbol: "key") {
                        Text(AppStrings.Settings.disabled)
                    }
                    TailscaleFormRow(label: AppStrings.Tailscale.operatingSystem, symbol: "desktopcomputer") {
                        Text(verbatim: "macOS")
                    }
                }
            }.formStyle(.grouped).environment(\.locale, Locale(identifier: language)), width: 360)
        defer { fixture.close() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            fixture.window.appearance = NSAppearance(named: appearance)
            try await fixture.settle()
            try fixture.capture("tailscale-rows-\(language)-\(appearance.rawValue)")
        }
    }
}

@MainActor
private final class TailscaleFormWindow {
    let window: NSWindow

    init(_ view: some View, width: CGFloat = 400) {
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: width, height: 650),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(
            rootView: view.frame(width: width, height: 650).coordinateSpace(name: "tailscale.test"))
        controller.sizingOptions = []
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 650)
        window.setContentSize(NSSize(width: width, height: 650))
        controller.view.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func settle() async throws {
        try await Task.sleep(for: .milliseconds(200))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func close() {
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
    }

    func click(_ pointInContent: NSPoint) throws {
        let view = try #require(window.contentView)
        let point = view.convert(pointInContent, to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try event(.leftMouseDown), atStart: false)
        NSApp.postEvent(try event(.leftMouseUp), atStart: false)
        let deadline = Date(timeIntervalSinceNow: 0.2)
        while Date() < deadline {
            if let next = NSApp.nextEvent(
                matching: .any, until: Date(timeIntervalSinceNow: 0.02), inMode: .default, dequeue: true
            ) {
                NSApp.sendEvent(next)
            }
        }
    }

    func capture(_ name: String) throws {
        let view = try #require(window.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(data, named: "\(name).png")
        try data.write(to: FileManager.default.temporaryDirectory.appending(path: "\(name).png"))
    }
}

@Suite @MainActor
struct TailscaleFormLayoutTests {
    @Test func longAddressesWrapInsteadOfGrowingTheFormWidth() {
        let value = "production-server-with-a-very-long-hostname.example-tailnet.ts.net"
        func size(at width: CGFloat) -> NSSize {
            let view = NSHostingView(
                rootView:
                    TailscaleCopyField(label: AppStrings.Tailscale.magicDNS, value: value, copy: { _ in })
                    .frame(width: width))
            return view.fittingSize
        }
        let narrow = size(at: 240)
        let wide = size(at: 600)
        #expect(narrow.width == 240)
        #expect(wide.width == 600)
        #expect(narrow.height > wide.height)
    }
}

private actor TailscaleFormPreviewNode: TailscaleNodeSession {
    let network: TailscaleNetwork
    init(network: TailscaleNetwork) { self.network = network }
    func status() async throws -> TailscaleNodeStatus {
        TailscaleNodeStatus(
            running: true, network: network, authURL: nil,
            peers: [
                TailscalePeer(
                    stableID: "offline", name: "Offline server", dnsName: "server.example.ts.net", online: false,
                    sshHostKeys: [], exitNodeOption: true)
            ],
            device: TailscaleDeviceInfo(
                networkName: "Example", dnsName: "macbook.example.ts.net", hostname: "MacBook",
                addresses: ["100.64.0.1", "fd7a:115c:a1e0::1234"], operatingSystem: "macOS", keyExpiry: nil))
    }
    func login() async throws {}
    func logout() async throws {}
    func close() async {}
    func dial(host: String, port: Int, timeout: TimeInterval) async throws -> Int32 {
        throw TailscaleConfigurationError.unavailable
    }
    func hostKeys(stableNodeID: String) async throws -> Set<SSHHostKeyIdentity> { [] }
    func setHostname(_ hostname: String) async throws {}
}
