import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import Testing

@testable import Termind

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct TailscaleDetailLayoutTests {
    @Test func openingSwitchingResizingAndClosingKeepsTheWindowResponsive() async throws {
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net")
        var group = HostGroup(name: "Tailnet")
        group.tailscale = TailscaleGroupConfiguration(network: network)
        let peers = ["first", "second"].map {
            TailscalePeer(
                stableID: $0, name: $0, dnsName: "\($0)-long-hostname.example.ts.net",
                online: true, sshHostKeys: ["fixture"],
                details: TailscalePeerDetails(
                    addresses: ["100.64.0.1", "fd7a:115c:a1e0::6235:ac3c"], operatingSystem: "linux"))
        }
        let store = InMemoryTailscaleLocalStore()
        try store.save(TailscaleLocalState(groupID: group.id, profileID: UUID(), peers: peers))
        let library = HostLibraryModel(groups: [group])
        let app = AppModel(
            hosts: library, tailscaleStore: store, proAccess: .testing(status: .verificationFailed))
        let model = WindowModel(vaultDestination: .hosts)
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let controller = NSHostingController(
            rootView: RootView(window: model).environment(app).modelContainer(container))
        let native = NSWindow(
            contentRect: CGRect(x: 232, y: 151, width: 1283, height: 801),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        native.animationBehavior = .none
        native.contentViewController = controller
        native.makeKeyAndOrderFront(nil)
        defer {
            app.shutdownForTermination()
            native.orderOut(nil)
            native.contentViewController = nil
            native.close()
        }
        try await settle(controller.view)
        let hosts = library.hosts
        #expect(hosts.count == 2)
        let originalDestination = model.selectedDestination
        for width in [1283.0, 950.0, 800.0] {
            native.setContentSize(CGSize(width: width, height: 801))
            for host in hosts {
                model.openVaultWork(.tailscaleDetails(host.id), on: .hosts)
                try await settle(controller.view)
                #expect(model.selectedDestination == originalDestination)
                #expect(native.attachedSheet == nil)
                #expect(model.vaultWorkRoute == .tailscaleDetails(host.id))
                let size = native.frame.size
                try await settle(controller.view)
                #expect(native.frame.size == size)
            }
            model.closeVaultWork()
            try await settle(controller.view)
            #expect(model.vaultWorkRoute == nil)
            #expect(model.selectedDestination == originalDestination)
        }
    }

    private func settle(_ view: NSView) async throws {
        try await Task.sleep(for: .milliseconds(400))
        view.layoutSubtreeIfNeeded()
    }

}
