import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit

import struct TermindDomain.Host

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileConnectionPickerTests {
    @Test func pickerDefaultsToSSHFiltersHostsAndReturnsTheSelectedProtocol() throws {
        let app = try MobileAppModel(inMemory: true)
        var selections: [(Host.ID, ConnectionHistoryEntry.Kind)] = []
        let hostModel = MobileHostPickerModel(library: app.library)
        let connectionModel = MobileConnectionPickerModel { selections.append(($0, $1)) }

        #expect(connectionModel.kind == .ssh)
        #expect(hostModel.isLibraryEmpty)

        let production = Host(name: "Production", host: "production.example.invalid")
        let staging = Host(name: "Staging", host: "staging.example.invalid")
        app.library.upsert(production)
        app.library.upsert(staging)

        #expect(!hostModel.isLibraryEmpty)
        #expect(Set(hostModel.hosts.map(\.id)) == Set([production.id, staging.id]))

        hostModel.query = "prod"
        #expect(hostModel.hosts.map(\.id) == [production.id])

        connectionModel.select(production)
        #expect(selections.count == 1)
        #expect(selections.first?.0 == production.id)
        #expect(selections.first?.1 == .ssh)

        connectionModel.kind = .sftp
        connectionModel.select(staging)
        #expect(selections.count == 2)
        #expect(selections.last?.0 == staging.id)
        #expect(selections.last?.1 == .sftp)
    }

    @Test func emptyWorkspaceHistoryKeepsTheLatestFiveUniqueLocalHosts() throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app)
        let repeatedHost = Host(
            name: "Repeated", host: "repeated.example.invalid",
            telnetEnabled: true, telnetPort: 2323)
        let otherHosts = (0..<4).map {
            Host(name: "Host \($0)", host: "host-\($0).example.invalid")
        }
        app.library.upsert(repeatedHost)
        for host in otherHosts { app.library.upsert(host) }

        let newestSSH = try #require(
            app.connectionHistory.record(kind: .ssh, for: repeatedHost.id, at: Date(timeIntervalSince1970: 70)))
        _ = app.connectionHistory.record(
            kind: .ssh, for: repeatedHost.id, at: Date(timeIntervalSince1970: 60))
        _ = app.connectionHistory.record(
            kind: .telnet, for: repeatedHost.id, at: Date(timeIntervalSince1970: 58))
        _ = app.connectionHistory.record(
            kind: .sftp, for: repeatedHost.id, at: Date(timeIntervalSince1970: 55))
        let other0 = try #require(
            app.connectionHistory.record(
                kind: .sftp, for: otherHosts[0].id, at: Date(timeIntervalSince1970: 50)))
        let other1 = try #require(
            app.connectionHistory.record(
                kind: .ssh, for: otherHosts[1].id, at: Date(timeIntervalSince1970: 40)))
        let other2 = try #require(
            app.connectionHistory.record(
                kind: .sftp, for: otherHosts[2].id, at: Date(timeIntervalSince1970: 30)))
        let other3 = try #require(
            app.connectionHistory.record(
                kind: .ssh, for: otherHosts[3].id, at: Date(timeIntervalSince1970: 20)))
        let expectedEntries = [newestSSH, other0, other1, other2, other3]
        _ = app.connectionHistory.record(
            kind: .ssh, for: UUID(), at: Date(timeIntervalSince1970: 80))

        let rows = MobileWorkspaceListView(app: app, scene: scene).historyRows

        #expect(rows.count == MobileWorkspaceListView.historyLimit)
        #expect(rows.map(\.entry.id) == expectedEntries.map(\.id))
        #expect(rows.first?.preferredKind == .ssh)
        #expect(rows.first?.loginAddress == app.library.loginAddress(for: repeatedHost, protocol: .ssh))
        #expect(Set(rows.map(\.host.id)).count == rows.count)
    }

    @Test func recentConnectionActionsFollowEveryHostProtocolCombination() {
        #expect(MobileConnectionHistoryActionPolicy.menuKinds == [.ssh, .telnet, .sftp])
        #expect(MobileConnectionHistoryActionPolicy.swipeKinds == [.sftp, .telnet, .ssh])

        var host = Host(name: "Remote", host: "remote.example.invalid")
        assertAvailability(host, ssh: true, telnet: false, sftp: true)
        #expect(MobileConnectionHistoryActionPolicy.availableMenuKinds(for: host) == [.ssh, .sftp])
        #expect(MobileConnectionHistoryActionPolicy.availableSwipeKinds(for: host) == [.sftp, .ssh])

        host.sshEnabled = false
        host.telnetEnabled = true
        assertAvailability(host, ssh: false, telnet: true, sftp: false)
        #expect(MobileConnectionHistoryActionPolicy.availableMenuKinds(for: host) == [.telnet])
        #expect(MobileConnectionHistoryActionPolicy.availableSwipeKinds(for: host) == [.telnet])

        host.sshEnabled = true
        assertAvailability(host, ssh: true, telnet: true, sftp: true)
        #expect(MobileConnectionHistoryActionPolicy.availableMenuKinds(for: host) == [.ssh, .telnet, .sftp])
        #expect(MobileConnectionHistoryActionPolicy.availableSwipeKinds(for: host) == [.sftp, .telnet, .ssh])

        host.sshEnabled = false
        host.telnetEnabled = false
        assertAvailability(host, ssh: false, telnet: false, sftp: false)
        #expect(MobileConnectionHistoryActionPolicy.availableMenuKinds(for: host).isEmpty)
        #expect(MobileConnectionHistoryActionPolicy.availableSwipeKinds(for: host).isEmpty)
        #expect(MobileConnectionHistory.preferredKind(for: host) == nil)

        host.telnetEnabled = true
        #expect(MobileConnectionHistory.preferredKind(for: host) == .telnet)
        host.sshEnabled = true
        #expect(MobileConnectionHistory.preferredKind(for: host) == .ssh)
    }

    @Test func unavailableHistoryEventStaysVisibleButCannotOpen() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = Host(
            name: "Legacy Telnet", host: "legacy.example.invalid",
            sshEnabled: true, telnetEnabled: false)
        app.library.upsert(host)
        _ = try #require(app.connectionHistory.record(kind: .telnet, for: host.id))

        let row = try #require(
            MobileConnectionHistory.eventRows(
                history: app.connectionHistory, devices: app.devices,
                library: app.library, limit: 1
            ).first)

        #expect(row.entry.kind == .telnet)
        #expect(!row.canOpen)
    }

    @Test func historyPageKeepsEveryEventSearchesDeviceNameAndCapsAtFifty() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = Host(name: "History", host: "history.example.invalid")
        app.library.upsert(host)
        let historyRepository = InMemoryConnectionHistoryRepository()
        let deviceRepository = InMemoryDeviceDirectoryRepository()
        for index in (0...MobileHistoryPresentation.limit).reversed() {
            let deviceID = UUID()
            try deviceRepository.upsert(
                DeviceRecord(id: deviceID, displayName: "device-\(index)"))
            try historyRepository.insert(
                ConnectionHistoryEntry(
                    hostID: host.id, kind: index.isMultiple(of: 2) ? .ssh : .sftp,
                    connectedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    sourceDeviceID: deviceID),
                limit: ConnectionHistoryModel.limit)
        }
        let history = ConnectionHistoryModel(repository: historyRepository)
        let devices = DeviceDirectoryModel(repository: deviceRepository)

        let rows = MobileConnectionHistory.eventRows(
            history: history, devices: devices, library: app.library,
            limit: MobileHistoryPresentation.limit)
        #expect(rows.count == MobileHistoryPresentation.limit)
        #expect(rows.first?.sourceDeviceName == "device-50")
        #expect(rows.filter { $0.host.id == host.id }.count == MobileHistoryPresentation.limit)
        #expect(MobileHistoryPresentation.limited(Array(0...50)) == Array(0..<50))

        let searched = MobileConnectionHistory.eventRows(
            history: history, devices: devices, library: app.library,
            query: "device-17", limit: MobileHistoryPresentation.limit)
        #expect(searched.map(\.sourceDeviceName) == ["device-17"])
    }

    @Test func availableRecentTelnetActionOpensATelnetWorkspace() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = Host(
            name: "Console", host: "console.example.invalid",
            sshEnabled: false, telnetEnabled: true)
        app.library.upsert(host)
        let scene = MobileSceneModel(app: app)
        defer { app.closeAll() }

        scene.open(hostID: host.id, kind: .telnet)
        scene.activatePendingWorkspace()

        #expect(scene.activeWorkspace?.descriptor.hostID == host.id)
        #expect(scene.activeWorkspace?.descriptor.kind == .telnet)
        #expect(app.connectionHistory.entries(for: host.id).map(\.kind) == [.telnet])
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["TERMIND_MOBILE_UI_TESTS"] == "1",
            "Set TERMIND_MOBILE_UI_TESTS=1 and disable parallel testing for key-window integration tests"),
        arguments: [HostUseCase.snippetExecution, .metrics])
    func multiHostPickerGatesConfirmationOnRequiredSelection(useCase: HostUseCase) async throws {
        let app = try MobileAppModel(inMemory: true)
        let host = Host(name: "Production", host: "production.example.invalid")
        app.library.upsert(host)

        try await withStandaloneNavigation(
            MobileMultiHostPicker(
                library: app.library, useCase: useCase, selected: [], title: "Run", actionTitle: "Run",
                emptyDescription: AppStrings.Snippets.addAHostBeforeChoosingDefaultTargets,
                requiresSelection: true, save: { _ in }),
            language: "en"
        ) { navigation in
            let run = try #require(toolbarButton(named: "Run", in: navigation))
            #expect(!run.isEnabled)
        }

        try await withStandaloneNavigation(
            MobileMultiHostPicker(
                library: app.library, useCase: useCase, selected: [host.id], title: "Add Hosts",
                actionTitle: "Done",
                emptyDescription: AppStrings.Snippets.addAHostBeforeChoosingDefaultTargets,
                requiresSelection: false, save: { _ in }),
            language: "en"
        ) { navigation in
            let done = try #require(toolbarButton(named: "Done", in: navigation))
            #expect(done.isEnabled)
        }
    }

    @Test(
        arguments: [
            ("en", "Connect", "More", "Close All"),
            ("zh-Hans", "连接", "更多", "全部关闭"),
            ("zh-Hant", "連線", "更多", "全部關閉"),
        ])
    func workspaceToolbarExposesLocalizedActions(
        language: String, expectedConnectName: String, expectedMoreName: String,
        expectedCloseAllName: String
    ) async throws {
        var connectActivations = 0
        try await withNavigation(
            ToolbarHost(
                hasWorkspaces: true,
                closeAll: {},
                connect: { connectActivations += 1 }),
            language: language
        ) { navigation in
            let connect = try #require(toolbarButton(named: expectedConnectName, in: navigation))
            let connectAction = try #require(connect.action)
            #expect(UIApplication.shared.sendAction(connectAction, to: connect.target, from: connect, for: nil))
            #expect(connectActivations == 1)

            let page = try #require(navigation.topViewController)
            let menu: UIMenu
            if #available(iOS 27.0, *) {
                menu = UIMenu(children: [try #require(page.navigationItem.additionalOverflowItems)])
            } else {
                let more = try #require(toolbarButton(named: expectedMoreName, in: navigation))
                #expect(more.isEnabled)
                menu = try #require(more.menu)
            }
            let actions = try await resolvedMenuActions(menu, in: page.view)
            let closeAll = try #require(actions.first { $0.title == expectedCloseAllName })
            #expect(closeAll.attributes.contains(.destructive))
            #expect(!closeAll.attributes.contains(.disabled))
            #expect(actions.count == 1)
        }
    }

    @Test func workspaceToolbarDisablesCloseAllWithoutWorkspaces() async throws {
        try await withNavigation(
            ToolbarHost(hasWorkspaces: false, closeAll: {}, connect: {}),
            language: "en"
        ) { navigation in
            let page = try #require(navigation.topViewController)
            let menu: UIMenu
            if #available(iOS 27.0, *) {
                menu = UIMenu(children: [try #require(page.navigationItem.additionalOverflowItems)])
            } else {
                menu = try #require(toolbarButton(named: "More", in: navigation)?.menu)
            }
            let actions = try await resolvedMenuActions(menu, in: page.view)
            let closeAll = try #require(actions.first { $0.title == "Close All" })
            #expect(closeAll.attributes.contains(.disabled))
            #expect(actions.contains { $0.title == "Clear History" } == false)
        }
    }

    private func withNavigation<Content: View>(
        _ content: Content,
        language: String,
        check: (UINavigationController) async throws -> Void
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: NavigationStack { content }.environment(\.locale, Locale(identifier: language)))
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(700))
        let navigation = try #require(descendant(of: UINavigationController.self, in: controller))
        try await check(navigation)
    }

    private func withStandaloneNavigation<Content: View>(
        _ content: Content,
        language: String,
        check: (UINavigationController) throws -> Void
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: content.environment(\.locale, Locale(identifier: language)))
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(700))
        let navigation = try #require(descendant(of: UINavigationController.self, in: controller))
        try check(navigation)
    }

    private func toolbarButton(named name: String, in navigation: UINavigationController) -> UIBarButtonItem? {
        guard let item = navigation.topViewController?.navigationItem else { return nil }
        let buttons =
            item.leadingItemGroups.flatMap(\.barButtonItems)
            + item.trailingItemGroups.flatMap(\.barButtonItems)
            + (item.leftBarButtonItems ?? [])
            + (item.rightBarButtonItems ?? [])
        return buttons.first { button in
            button.accessibilityLabel == name || button.title == name || button.customView?.accessibilityLabel == name
        }
    }

    private func resolvedMenuActions(_ menu: UIMenu, in view: UIView) async throws -> [UIAction] {
        let button = UIButton(frame: CGRect(x: 20, y: 100, width: 44, height: 44))
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        view.addSubview(button)
        defer { button.removeFromSuperview() }
        button.performPrimaryAction()
        try await Task.sleep(for: .milliseconds(500))
        let interaction = try #require(button.contextMenuInteraction)
        var actions: [UIAction] = []
        interaction.updateVisibleMenu { resolved in
            actions = menuActions(resolved)
            return resolved
        }
        interaction.dismissMenu()
        try await Task.sleep(for: .milliseconds(300))
        return actions
    }

    private func menuActions(_ menu: UIMenu) -> [UIAction] {
        menu.children.flatMap { element -> [UIAction] in
            if let action = element as? UIAction { return [action] }
            if let submenu = element as? UIMenu { return menuActions(submenu) }
            return []
        }
    }

    private func descendant<T: UIViewController>(of type: T.Type, in controller: UIViewController) -> T? {
        var pending = [controller]
        var visited = Set<ObjectIdentifier>()
        while let next = pending.popLast() {
            guard visited.insert(ObjectIdentifier(next)).inserted else { continue }
            if let result = next as? T { return result }
            pending.append(contentsOf: next.children)
            if let presented = next.presentedViewController { pending.append(presented) }
        }
        return nil
    }

    private func assertAvailability(
        _ host: Host, ssh: Bool, telnet: Bool, sftp: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            MobileConnectionHistoryActionPolicy.isAvailable(.ssh, for: host) == ssh,
            sourceLocation: sourceLocation)
        #expect(
            MobileConnectionHistoryActionPolicy.isAvailable(.telnet, for: host) == telnet,
            sourceLocation: sourceLocation)
        #expect(
            MobileConnectionHistoryActionPolicy.isAvailable(.sftp, for: host) == sftp,
            sourceLocation: sourceLocation)
    }
}

private struct ToolbarHost: View {
    let hasWorkspaces: Bool
    let closeAll: () -> Void
    let connect: () -> Void

    var body: some View {
        Color.clear
            .navigationTitle("Workspaces")
            .toolbar {
                MobileWorkspaceToolbar(
                    hasWorkspaces: hasWorkspaces,
                    closeAll: closeAll,
                    connect: connect
                )
            }
    }
}
