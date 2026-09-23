import Foundation
import SwiftData
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPersistence
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite @MainActor
struct MobileCardTests {
    @Test func workspaceConnectionIndicatorHidesDisconnectedWorkspaces() {
        #expect(
            MobileWorkspaceConnectionIndicator.resolve(
                connected: false, busy: false, reconnecting: false
            ) == nil
        )
        #expect(
            MobileWorkspaceConnectionIndicator.resolve(
                connected: true, busy: false, reconnecting: false
            ) == .connected
        )
        #expect(
            MobileWorkspaceConnectionIndicator.resolve(
                connected: false, busy: true, reconnecting: false
            ) == .busy
        )
        #expect(
            MobileWorkspaceConnectionIndicator.resolve(
                connected: false, busy: false, reconnecting: true
            ) == .busy
        )
    }

    @Test func cardColumnsFollowContainerWidthOnEveryDevice() {
        for width: CGFloat in [0, 288, 370, 660, 1024] {
            #expect(MobileCardLayout.columns(width: width, accessibilitySize: true) == 1)
        }
        #expect(MobileCardLayout.columns(width: 0, accessibilitySize: false) == 1)
        #expect(MobileCardLayout.columns(width: 651, accessibilitySize: false) == 1)
        #expect(MobileCardLayout.columns(width: 652, accessibilitySize: false) == 2)
        #expect(MobileCardLayout.columns(width: 983, accessibilitySize: false) == 2)
        #expect(MobileCardLayout.columns(width: 984, accessibilitySize: false) == 3)
    }

    @Test func standardCardHeightDoesNotChangeWithHostTags() {
        let noTags = measuredHeight(of: standardCard(tags: []))
        let oneTag = measuredHeight(of: standardCard(tags: ["production"]))
        let manyTags = measuredHeight(
            of: standardCard(tags: ["production", "a-very-long-tag-that-must-not-wrap", "hidden"]))
        let actionNoTags = measuredHeight(of: standardActionCard(tags: []))
        let actionManyTags = measuredHeight(
            of: standardActionCard(tags: ["production", "a-very-long-tag-that-must-not-wrap", "hidden"]))

        #expect(noTags >= MobileCardLayout.minimumHeight)
        #expect(abs(noTags - oneTag) <= 1)
        #expect(abs(noTags - manyTags) <= 1)
        #expect(actionNoTags >= MobileCardLayout.minimumHeight)
        #expect(abs(actionNoTags - actionManyTags) <= 1)
    }

    @Test func hostCardsShowAtMostTwoTags() {
        #expect(Array(MobileCardLayout.visibleTags([])).isEmpty)
        #expect(Array(MobileCardLayout.visibleTags(["one"])) == ["one"])
        #expect(Array(MobileCardLayout.visibleTags(["one", "two", "three"])) == ["one", "two"])
    }

    @Test func forwardingCardsMatchHostHeightWithOrWithoutNames() {
        for width: CGFloat in [320, 398, 600] {
            let hostHeight = measuredHeight(of: standardActionCard(tags: ["production"]), width: width)
            for kind in PortForwardingRule.Kind.allCases {
                for name in ["", "Database with a long display name that stays on one line"] {
                    let rule = PortForwardingRule(
                        hostID: UUID(), kind: kind, targetHost: "database.production.example.invalid", label: name)
                    let card = MobileActionCard(
                        action: {},
                        content: { MobileForwardingCardContent(rule: rule, hostName: "Production", runtime: .stopped) },
                        actions: { EmptyView() })
                    #expect(abs(measuredHeight(of: card, width: width) - hostHeight) <= 1)
                }
            }
        }
    }

    @Test func unnamedForwardingUsesTheHostAndSSHArgument() {
        for (kind, argument) in [(PortForwardingRule.Kind.local, "-L"), (.remote, "-R"), (.dynamic, "-D")] {
            var rule = PortForwardingRule(hostID: UUID(), kind: kind)
            #expect(rule.displayName(hostName: "AWS") == "AWS (\(argument))")
            rule.label = "Database"
            #expect(rule.displayName(hostName: "AWS") == "Database")
            rule.label = "  "
            #expect(rule.displayName(hostName: "AWS") == "AWS (\(argument))")
        }
    }

    @Test func knownHostEditorDistinguishesAddAndEditTitles() throws {
        let app = try MobileAppModel(inMemory: true)
        let saved = KnownHostEntry(hostname: "saved.example", fingerprint: "SHA256:saved")
        #expect(app.knownHosts.save(saved))

        let add = MobileKnownHostEditor(app: app, entry: KnownHostEntry(hostname: ""))
        let edit = MobileKnownHostEditor(app: app, entry: saved)

        #expect(add.isNew)
        #expect(add.editorTitle == String(localized: "Add Known Host"))
        #expect(!edit.isNew)
        #expect(edit.editorTitle == String(localized: "Edit Known Host"))
    }

    @Test func hostSectionsFoldNestedGroupsKeepEmptyGroupsAndLeaveSearchAvailable() throws {
        let app = try MobileAppModel(inMemory: true)
        let root = HostGroup(name: "Production")
        let child = HostGroup(name: "Edge", parentID: root.id)
        let empty = HostGroup(name: "Empty")
        let rootHost = TermindDomain.Host(name: "Gateway", host: "gateway.example", groupID: root.id)
        let childHost = TermindDomain.Host(name: "Child Node", host: "edge.example", groupID: child.id)
        let ungroupedHost = TermindDomain.Host(name: "Loose", host: "loose.example")

        app.library.upsert(root)
        app.library.upsert(child)
        app.library.upsert(empty)
        app.library.upsert(rootHost)
        app.library.upsert(childHost)
        app.library.upsert(ungroupedHost)

        let expanded = HostLibrarySectionLayout.sections(library: app.library)
        #expect(
            expanded.map(\.id)
                == [.group(root.id), .group(child.id), .group(empty.id), .ungrouped])
        #expect(expanded.map(\.title) == ["Production", "Production / Edge", "Empty", "Ungrouped"])
        #expect(expanded.first(where: { $0.id == .group(empty.id) })?.hosts.isEmpty == true)

        app.library.setExpanded(false, for: root.id)
        let collapsed = HostLibrarySectionLayout.sections(library: app.library)
        #expect(collapsed.map(\.id) == [.group(root.id), .group(empty.id), .ungrouped])
        #expect(app.library.searchHosts("Child Node").map(\.id) == [childHost.id])

        app.library.setUngroupedExpanded(false)
        #expect(
            HostLibrarySectionLayout.sections(library: app.library)
                .first(where: { $0.id == .ungrouped })?.isExpanded == false)

        let stored = try HostPersistence(context: ModelContext(app.container)).load()
        #expect(stored.groups.first(where: { $0.id == root.id })?.isExpanded == true)
    }

    @Test func distributionBrandColorsAreValidAndReadableOnHostIconSurfaces() throws {
        #expect(LinuxDistributionBrandColor.color(hex: "not-a-color", colorScheme: .light) == nil)

        for scheme in [ColorScheme.light, .dark] {
            let color = try #require(LinuxDistributionBrandColor.color(hex: "000000", colorScheme: scheme))
            let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
            let foreground = try components(UIColor(color))
            let surface = try components(
                UIColor.secondarySystemGroupedBackground.resolvedColor(with: traits))
            let tintedSurface = mix(surface, foreground, amount: 0.16)
            #expect(contrastRatio(foreground, tintedSurface) >= 3)
        }
    }

    @Test func openingSavedHostsRecordsSSHAndSFTPForTheCardTimestamp() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)

        let ssh = try #require(app.open(hostID: host.id, kind: .ssh))
        let sftp = try #require(app.open(hostID: host.id, kind: .sftp))

        #expect(Set(app.connectionHistory.entries(for: host.id).map(\.kind)) == [.ssh, .sftp])
        #expect(
            app.connectionHistory.entries(for: host.id).allSatisfy {
                app.devices.name(for: $0.sourceDeviceID)?.isEmpty == false
            })
        #expect(app.connectionHistory.entries(for: host.id).allSatisfy { $0.endedAt == nil })
        #expect(app.lastConnectedAt(for: host.id) != nil)
        let restored = ConnectionHistoryModel(
            repository: SwiftDataConnectionHistoryRepository(context: ModelContext(app.container)))
        #expect(Set(restored.entries(for: host.id).map(\.kind)) == [.ssh, .sftp])

        app.close(ssh)
        app.close(sftp)
        #expect(app.connectionHistory.entries(for: host.id).allSatisfy { $0.endedAt != nil })
    }

    @Test func hostAndIdentityColorsRemainDraftsUntilSavedAndRoundTripThroughPersistence() throws {
        let app = try MobileAppModel(inMemory: true)
        var host = TermindDomain.Host(name: "Test", host: "example.invalid", colorTag: .teal)
        var identity = Identity(name: "Deploy", username: "deploy", colorTag: .purple)
        app.library.upsert(host)
        #expect(app.library.upsert(identity))
        host.colorTag = .pink
        identity.colorTag = .orange
        #expect(app.library.host(host.id)?.colorTag == .teal)
        #expect(app.credentials.identities.first?.colorTag == .purple)
        app.library.upsert(host)
        #expect(app.library.upsert(identity))
        let saved = try HostPersistence(context: ModelContext(app.container)).load()
        #expect(saved.hosts.first?.colorTag == .pink)
        #expect(saved.identities.first?.colorTag == .orange)
        host.colorTag = .none
        identity.colorTag = .none
        app.library.upsert(host)
        #expect(app.library.upsert(identity))
        let cleared = try HostPersistence(context: ModelContext(app.container)).load()
        #expect(cleared.hosts.first?.colorTag == TagColor.none)
        #expect(cleared.identities.first?.colorTag == TagColor.none)
    }

    @Test func generatedImportedAndEditedKeysPreserveColorWithoutSavingCancelledDrafts() async throws {
        let app = try MobileAppModel(inMemory: true)
        let generator = MobileKeyEditorModel(mode: .generate, credentials: app.credentials)
        generator.label = "Colored Key"
        generator.colorTag = .green
        #expect(generator.isDirty)
        try await generator.save()
        let key = try #require(app.credentials.keys.first)
        #expect(key.colorTag == .green)
        let credential = try #require(try app.credentials.keyCredential(for: key))
        guard case .software(let secret) = credential else {
            Issue.record("Expected software key")
            return
        }
        let importer = MobileKeyEditorModel(mode: .importKey, credentials: app.credentials)
        importer.label = "Imported Color"
        importer.privateKey = secret.privateKey
        importer.colorTag = .blue
        try await importer.save()
        #expect(app.credentials.keys.first(where: { $0.label == "Imported Color" })?.colorTag == .blue)

        let editor = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: key)
        await editor.loadPrivateKey()
        #expect(editor.colorTag == .green && !editor.isDirty)
        editor.colorTag = .red
        #expect(editor.isDirty)
        #expect(app.credentials.key(key.id)?.colorTag == .green)
        editor.colorTag = .none
        try await editor.save()
        let updated = try #require(app.credentials.key(key.id))
        let reopened = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: updated)
        await reopened.loadPrivateKey()
        #expect(reopened.colorTag == .none && !reopened.isDirty)
        #expect(updated.fingerprint == key.fingerprint)
    }

    private func standardCard(tags: [String]) -> some View {
        MobileCard { standardCardContent(tags: tags) }
    }

    private func standardActionCard(tags: [String]) -> some View {
        MobileActionCard(
            action: {},
            content: { standardCardContent(tags: tags) },
            actions: { EmptyView() }
        )
    }

    private func standardCardContent(tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                MobileCardIcon(symbol: "server.rack")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Production").font(.headline).lineLimit(1)
                    Text("deploy@example.invalid").font(.caption.monospaced()).lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                ForEach(MobileCardLayout.visibleTags(tags), id: \.self) { MobileCardChip(text: $0) }
                Spacer(minLength: 6)
                Text("1 hr ago").font(.caption2).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func measuredHeight<V: View>(of view: V, width: CGFloat = 320) -> CGFloat {
        let controller = UIHostingController(rootView: view.environment(\.dynamicTypeSize, .large))
        return controller.sizeThatFits(in: CGSize(width: width, height: 1_000)).height
    }

    private func components(_ color: UIColor) throws -> (CGFloat, CGFloat, CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        #expect(color.getRed(&red, green: &green, blue: &blue, alpha: nil))
        return (red, green, blue)
    }

    private func mix(
        _ lhs: (CGFloat, CGFloat, CGFloat), _ rhs: (CGFloat, CGFloat, CGFloat), amount: CGFloat
    ) -> (CGFloat, CGFloat, CGFloat) {
        (
            lhs.0 + (rhs.0 - lhs.0) * amount,
            lhs.1 + (rhs.1 - lhs.1) * amount,
            lhs.2 + (rhs.2 - lhs.2) * amount
        )
    }

    private func contrastRatio(
        _ lhs: (CGFloat, CGFloat, CGFloat), _ rhs: (CGFloat, CGFloat, CGFloat)
    ) -> CGFloat {
        let lighter = max(luminance(lhs), luminance(rhs))
        let darker = min(luminance(lhs), luminance(rhs))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ color: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.0) + 0.7152 * linear(color.1) + 0.0722 * linear(color.2)
    }
}
