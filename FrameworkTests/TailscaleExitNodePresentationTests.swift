import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindPresentation

@Suite @MainActor
struct TailscaleExitNodePresentationTests {
    @Test(arguments: [false, true])
    func selectingAnExitNodeRequiresItToBeOnlineAndOnlyChangesTheDraft(online: Bool) async throws {
        let (model, library, group) = try fixture(online: online)
        let editor = TailscaleGroupEditor(model: model, group: group)
        let field = TailscaleExitNodeField(editor: editor)
        field.selection.wrappedValue = "candidate"
        #expect(editor.exitNodeID == (online ? "candidate" : "current"))
        #expect(library.group(group.id)?.tailscale?.exitNodeID == "current")
        field.selection.wrappedValue = "missing"
        #expect(editor.exitNodeID == (online ? "candidate" : "current"))
        field.selection.wrappedValue = ""
        #expect(editor.exitNodeID.isEmpty)
        #expect(library.group(group.id)?.tailscale?.exitNodeID == "current")
        await model.shutdown()
    }

    @Test func anOfflineCurrentSelectionIsRetainedUntilTheUserChangesIt() async throws {
        let (model, _, group) = try fixture(online: false)
        let editor = TailscaleGroupEditor(model: model, group: group)
        let field = TailscaleExitNodeField(editor: editor)
        #expect(field.selection.wrappedValue == "current")
        field.selection.wrappedValue = "candidate"
        #expect(field.selection.wrappedValue == "current")
        editor.cancel()
        let reopened = TailscaleGroupEditor(model: model, group: group)
        #expect(reopened.exitNodeID == "current")
        await model.shutdown()
    }

    private func fixture(online: Bool) throws -> (TailscaleModel, HostLibraryModel, HostGroup) {
        var group = HostGroup(name: "Test Tailnet")
        group.tailscale = TailscaleGroupConfiguration(
            network: try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "test.ts.net"))
        group.tailscale?.exitNodeID = "current"
        let library = HostLibraryModel(groups: [group])
        let store = InMemoryTailscaleLocalStore()
        try store.save(
            TailscaleLocalState(
                groupID: group.id, profileID: UUID(),
                peers: [
                    TailscalePeer(
                        stableID: "current", name: "Current", dnsName: "current.test.ts.net", online: false,
                        sshHostKeys: [], exitNodeOption: true),
                    TailscalePeer(
                        stableID: "candidate", name: "Candidate", dnsName: "candidate.test.ts.net", online: online,
                        sshHostKeys: [], exitNodeOption: true),
                ]))
        let model = TailscaleModel(
            library: library, store: store, factory: { _, _, _, _ in throw TailscaleConfigurationError.unavailable },
            profileStorage: .disabled, hostname: { "test-device" }, hasAccess: { false })
        model.start()
        return (model, library, group)
    }
}
