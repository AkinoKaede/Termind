import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite @MainActor
struct AgentPaneToolsTests {
    private final class Fixture {
        let first = UUID()
        let second = UUID()
        var current: UUID?
        var open: Set<UUID>
        var connected: Set<UUID>
        var texts: [UUID: String]

        init() {
            open = [first, second]
            connected = [first, second]
            texts = [first: "first  \n\nlast", second: ""]
            current = first
        }

        func access() -> AgentPaneAccess {
            AgentPaneAccess(
                list: { [self] in
                    [first, second].compactMap { id in
                        guard open.contains(id), connected.contains(id), texts[id] != nil else { return nil }
                        return pane(id)
                    }
                },
                read: { [self] id in
                    guard open.contains(id) else { return .closed }
                    guard connected.contains(id) else { return .notConnected }
                    guard let text = texts[id] else { return .noSurface }
                    return .text(pane(id), text)
                })
        }

        func pane(_ id: UUID) -> AgentPaneAccess.Pane {
            AgentPaneAccess.Pane(
                id: id, title: id == first ? "front" : "hidden", hostID: id,
                workspace: id == first ? "one" : "two", window: id == first ? "window-1" : "window-2",
                isActive: id == first, isCurrent: id == current)
        }
    }

    private func invocation(_ name: String, paneID: String? = nil) -> AgentToolInvocation {
        AgentToolInvocation(
            runID: UUID(),
            call: .init(
                id: UUID().uuidString, name: name,
                arguments: .object(paneID.map { ["pane_id": .string($0)] } ?? [:])))
    }

    private func context(_ invocation: AgentToolInvocation) -> AgentToolExecutionContext {
        AgentToolExecutionContext(
            runID: invocation.runID, userIntent: "Inspect the terminal",
            secretBroker: SecretBroker(), userInteraction: UnavailableAgentUserInteraction(),
            preflightMetadata: [:], authorize: { _ in .allow })
    }

    private func payload(_ result: AgentToolResult) throws -> [String: AgentJSONValue] {
        let raw = try #require(result.untrustedPayload)
        return try #require(AgentJSONValue.decode(Data(raw.utf8)).objectValue)
    }

    @Test
    func listingOnlyReturnsReadableMetadataAndMarksWindowFocus() async throws {
        let fixture = Fixture()
        let call = invocation("list_panes")
        let result = try await ListPanesTool(panes: fixture.access()).execute(call, context: context(call))
        let rows = try #require(payload(result)["panes"]?.arrayValue)
        #expect(rows.count == 2)
        #expect(rows[0].objectValue?["is_active"] == .bool(true))
        #expect(rows[0].objectValue?["is_current"] == .bool(true))
        #expect(rows[1].objectValue?["is_current"] == .bool(false))
        #expect(rows[1].objectValue?["title"] == .string("hidden"))
        #expect(!result.content.contains("first"))
        fixture.connected.remove(fixture.second)
        fixture.texts[fixture.first] = nil
        let filtered = try await ListPanesTool(panes: fixture.access()).execute(call, context: context(call))
        #expect(try #require(payload(filtered)["panes"]?.arrayValue).isEmpty)
    }

    @Test
    func readUsesTheExplicitTargetEvenAfterFocusMovesWithoutListingAgain() async throws {
        let fixture = Fixture()
        var listings = 0
        let access = fixture.access()
        let tool = ReadPaneTool(
            panes: AgentPaneAccess(
                list: {
                    listings += 1
                    return access.list()
                }, read: access.read))
        let explicit = invocation("read_pane", paneID: fixture.first.uuidString)
        fixture.current = fixture.second
        let second = invocation("read_pane", paneID: fixture.second.uuidString)
        let empty = try await tool.execute(second, context: context(second))
        #expect(try payload(empty)["pane_id"] == .string(fixture.second.uuidString))
        #expect(try payload(empty)["text"] == .string(""))
        #expect(try payload(empty)["truncated"] == .bool(false))

        let first = try await tool.execute(explicit, context: context(explicit))
        #expect(try payload(first)["text"] == .string("first  \n\nlast"))
        #expect(try payload(first)["pane_id"] == .string(fixture.first.uuidString))
        #expect(listings == 0)
    }

    @Test
    func missingIDIsRejectedEvenWhenACurrentTerminalExists() async throws {
        var listings = 0
        var reads = 0
        let fixture = Fixture()
        let tool = ReadPaneTool(
            panes: AgentPaneAccess(
                list: {
                    listings += 1
                    return [fixture.pane(fixture.first)]
                },
                read: { id in
                    reads += 1
                    return .text(fixture.pane(id), "must not be read")
                }))
        let call = invocation("read_pane")
        #expect(tool.descriptor.inputSchema.objectValue?["required"]?.arrayValue?.contains(.string("pane_id")) == true)
        await #expect(throws: AgentToolError.self) {
            try await tool.execute(call, context: context(call))
        }
        #expect(listings == 0)
        #expect(reads == 0)
    }

    @Test
    func invalidIDClosedDisconnectedAndNoSurfaceDoNotFallback() async throws {
        let fixture = Fixture()
        let tool = ReadPaneTool(panes: fixture.access())
        fixture.current = nil
        let implicit = invocation("read_pane")
        await #expect(throws: AgentToolError.self) {
            try await tool.execute(implicit, context: context(implicit))
        }
        for id in ["invalid", UUID().uuidString] {
            let call = invocation("read_pane", paneID: id)
            await #expect(throws: AgentToolError.self) {
                try await tool.execute(call, context: context(call))
            }
        }
        fixture.connected.remove(fixture.first)
        let disconnected = invocation("read_pane", paneID: fixture.first.uuidString)
        await #expect(throws: AgentToolError.self) {
            try await tool.execute(disconnected, context: context(disconnected))
        }
        fixture.connected.insert(fixture.first)
        fixture.texts[fixture.first] = nil
        await #expect(throws: AgentToolError.self) {
            try await tool.execute(disconnected, context: context(disconnected))
        }
        fixture.open.remove(fixture.first)
        await #expect(throws: AgentToolError.self) {
            try await tool.execute(disconnected, context: context(disconnected))
        }
    }

    @Test
    func readTruncatesOnUnicodeBoundaryWithoutNormalizingLines() async throws {
        let input = "α  \n" + String(repeating: "😀", count: 20_000)
        let (limited, truncated) = ReadPaneTool.limitUTF8(input)
        #expect(truncated)
        #expect(limited.utf8.count <= 65_536)
        #expect(limited.hasPrefix("α  \n"))
        #expect(String(decoding: Array(limited.utf8), as: UTF8.self) == limited)
        #expect(!ReadPaneTool.limitUTF8("  \n\n").1)
    }

    @Test
    func cardsShowOnlyNamesIDsAndStatesEvenWithoutPresenter() async throws {
        let fixture = Fixture()
        let readCall = invocation("read_pane", paneID: fixture.first.uuidString)
        let readTool = ReadPaneTool(panes: fixture.access())
        let readResult = try await readTool.execute(readCall, context: context(readCall))
        let card = AgentToolCard(
            invocation: readCall, descriptor: readTool.descriptor, state: .completed, result: readResult)
        #expect(AgentToolPresentation.summary(for: card, locale: Locale(identifier: "en")) == "Read terminal front")
        #expect(AgentToolPresentation.summary(for: card, locale: Locale(identifier: "zh-Hans")) == "读取终端“front”")
        let detail = try #require(AgentToolPresentation.detail(for: card, locale: Locale(identifier: "en")))
        #expect(detail.items.count == 2)
        #expect(!String(describing: detail).contains("first  "))
        #expect(String(describing: detail).contains(fixture.first.uuidString))
        let direct = ReadPaneTool.present(
            .init(
                result: try AgentJSONValue.decode(Data(try #require(readResult.untrustedPayload).utf8)),
                arguments: [:], locale: Locale(identifier: "en")))
        #expect(!String(describing: direct).contains("first  "))
        let directHans = ReadPaneTool.present(
            .init(
                result: try AgentJSONValue.decode(Data(try #require(readResult.untrustedPayload).utf8)),
                arguments: [:], locale: Locale(identifier: "zh-Hans")))
        #expect(String(describing: directHans).contains("终端名称"))
        #expect(!String(describing: directHans).contains("first  "))
        let restoredStyle = AgentToolCard(
            invocation: readCall, descriptor: readTool.descriptor, state: .completed,
            result: AgentToolResult(callID: readCall.call.id, content: readResult.content))
        let restoredDetail = try #require(
            AgentToolPresentation.detail(
                for: restoredStyle, presenter: TermindAgentTools.presenter(for: readTool.descriptor)))
        #expect(!String(describing: restoredDetail).contains("first  "))

        let listCall = invocation("list_panes")
        let listTool = ListPanesTool(panes: fixture.access())
        let listResult = try await listTool.execute(listCall, context: context(listCall))
        let listCard = AgentToolCard(
            invocation: listCall, descriptor: listTool.descriptor, state: .completed, result: listResult)
        #expect(AgentToolPresentation.summary(for: listCard, locale: Locale(identifier: "en")) == "List terminals")
        #expect(AgentToolPresentation.summary(for: listCard, locale: Locale(identifier: "zh-Hant")) == "列出終端")
        let listDetail = try #require(AgentToolPresentation.detail(for: listCard, locale: Locale(identifier: "en")))
        #expect(String(describing: listDetail).contains("hidden"))
        #expect(String(describing: listDetail).contains("Active"))
        #expect(String(describing: listDetail).contains("Current"))
        #expect(!String(describing: listDetail).contains("\"panes\""))
        let directHant = ListPanesTool.present(
            .init(
                result: try AgentJSONValue.decode(Data(try #require(listResult.untrustedPayload).utf8)),
                arguments: [:], locale: Locale(identifier: "zh-Hant")))
        #expect(String(describing: directHant).contains("此視窗已啟用"))
        #expect(String(describing: directHant).contains("目前助理視窗"))
    }

    @Test
    func batchesDescribeListingAndReadingIncludingRestoredCardsAndFailures() {
        let fixture = Fixture()
        let descriptors = [
            ListPanesTool(panes: fixture.access()).descriptor,
            ReadPaneTool(panes: fixture.access()).descriptor,
        ]
        for legacy in [false, true] {
            let cards = descriptors.map { descriptor in
                AgentToolCard(
                    invocation: invocation(descriptor.name),
                    descriptor: legacy
                        ? AgentToolDescriptor(
                            name: descriptor.name, summary: descriptor.summary,
                            inputSchema: descriptor.inputSchema, target: .local, approvalPolicy: .approve,
                            presentation: .init(
                                symbol: "terminal",
                                activity: .label(descriptor.name == "list_panes" ? "terminals" : "terminal")))
                        : descriptor,
                    state: .completed)
            }
            #expect(
                AgentToolPresentation.batchSummary(for: cards, locale: Locale(identifier: "en"))
                    == "Listed terminals, read terminal")
            #expect(
                AgentToolPresentation.batchSummary(for: cards, locale: Locale(identifier: "zh-Hans"))
                    == "已列出终端，已读取终端")
            #expect(
                AgentToolPresentation.batchSummary(for: cards, locale: Locale(identifier: "zh-Hant"))
                    == "已列出終端，已讀取終端")
            let failed = AgentToolCard(
                invocation: invocation("read_pane"), descriptor: cards[1].descriptor, state: .failed)
            #expect(
                AgentToolPresentation.batchSummary(
                    for: [cards[0], cards[1], cards[1], failed], locale: Locale(identifier: "en"))
                    == "Listed terminals, read terminal (2 times), failed to read terminal")
        }
        let mcp = AgentToolDescriptor(
            name: "read_pane", summary: "Unrelated MCP tool", inputSchema: .object([:]),
            target: .mcp, approvalPolicy: .approve)
        let card = AgentToolCard(invocation: invocation("read_pane"), descriptor: mcp, state: .completed)
        #expect(AgentToolPresentation.batchSummary(for: [card], locale: Locale(identifier: "en")) != "Read terminal")
    }

    @Test
    func largeReadMarksSourceTruncationInResultAndModelProjection() async throws {
        let fixture = Fixture()
        fixture.texts[fixture.first] = String(repeating: "😀", count: 20_000)
        let call = invocation("read_pane", paneID: fixture.first.uuidString)
        let tool = ReadPaneTool(panes: fixture.access())
        let result = try await tool.execute(call, context: context(call))
        #expect(result.isTruncated)
        #expect(try payload(result)["truncated"] == .bool(true))
        #expect(try #require(payload(result)["text"]?.stringValue).utf8.count == 65_536)
        let projected = await AgentToolOutputProjection(maximumBytes: 128).project(result, invocation: call)
        let model = try #require(projected.modelContent)
        #expect(model.contains("\"source_truncated\":true"))
        #expect(model.contains("source_notice"))

        let card = AgentToolCard(invocation: call, descriptor: tool.descriptor, state: .completed, result: result)
        #expect(!AgentToolPresentation.showsOutputTruncatedNotice(for: card))
        let mcp = AgentToolDescriptor(
            name: "read_pane", summary: "A separate MCP tool", inputSchema: .object([:]),
            target: .mcp, approvalPolicy: .approve, concurrency: .parallel)
        let mcpCard = AgentToolCard(invocation: call, descriptor: mcp, state: .completed, result: result)
        #expect(AgentToolPresentation.showsOutputTruncatedNotice(for: mcpCard))
    }

    @Test
    func paneToolsAreAvailableInPlanningAndActingOnlyWhenInjected() {
        let resolver = AgentHostResolver(store: HostLibraryModel())
        let connections = AgentConnectionPool(
            configuration: { _ in throw AgentToolError.invalidHost },
            routeFingerprint: { _ in "" },
            openConnection: { _ in throw AgentToolError.invalidHost },
            openSFTP: { _ in throw AgentToolError.invalidHost },
            sweepInterval: nil)
        func registry(_ panes: AgentPaneAccess?) -> AgentToolRegistry {
            AgentToolRegistry(
                TermindAgentTools.tools(
                    in: .init(
                        hosts: resolver, metrics: TestMetricsReader(), connections: connections, panes: panes)))
        }
        #expect(registry(nil)["list_panes"] == nil)
        let injected = registry(Fixture().access())
        #expect(injected.available(in: .planning)["list_panes"] != nil)
        #expect(injected.available(in: .planning)["read_pane"] != nil)
        #expect(injected.available(in: .acting)["list_panes"] != nil)
        #expect(injected.available(in: .acting)["read_pane"] != nil)
        #expect(injected.available(in: .reviewing)["read_pane"] == nil)
    }

    @Test
    func desktopAdapterExcludesDisconnectedAndSurfaceLessSSHtelnetSerialPanes() throws {
        let host = Host(name: "test", host: "test.invalid", telnetEnabled: true)
        let app = AppModel(
            hosts: HostLibraryModel(hosts: [host]),
            dependencies: .inMemory(hosts: [host], groups: []))
        let window = WindowModel()
        let ssh = SSHSessionModel(hostID: host.id, title: "ssh")
        let telnet = TelnetSessionModel(host: host)
        let serial = SerialSessionModel(
            configuration: SerialConnectionConfiguration(devicePath: "/dev/termind-test"),
            service: SystemSerialPortService())
        let panes = [Pane(.sshSession(ssh)), Pane(.telnetSession(telnet)), Pane(.serialSession(serial))]
        let workspaces = panes.map(Workspace.init(pane:))
        window.workspaces = workspaces
        window.selectedDestination = .workspace(workspaces[0].id)
        app.registerWindow(window)
        let access = app.paneAccess(for: window)
        #expect(access.list().isEmpty)
        for pane in panes {
            #expect(access.read(pane.id) == .notConnected)
        }
        ssh.status = .connected
        telnet.status = .connected
        serial.status = .connected
        #expect(access.list().isEmpty)
        for pane in panes {
            #expect(access.read(pane.id) == .noSurface)
        }
        app.unregisterWindow(window)
    }
}
