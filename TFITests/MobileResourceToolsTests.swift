// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import SwiftUI
import TermindApplication
import TermindPresentation
import TermindRemoteInfrastructure
import Testing
import UIKit

@testable import TermindIOS

@Suite @MainActor
struct MobileResourceToolsTests {
    @Test func longPublicMaterialDoesNotGrowTheMobileCardWithoutBound() throws {
        func card(_ repeats: Int) throws -> ResourceToolCardContent {
            let name = TermindToolName.getKey
            let value = AgentJSONValue.object([
                "label": .string("Deployment key"), "algorithm": .string("ssh-ed25519"),
                "storage": .string("thisDevice"), "availability": .string("available"),
                "public_key": .string("ssh-ed25519 " + String(repeating: "PUBLIC", count: repeats)),
                "certificate": .string(String(repeating: "CERTIFICATE\n", count: repeats)),
            ])
            let card = AgentToolCard(
                invocation: .init(runID: UUID(), call: .init(id: "call", name: name, arguments: .object([:]))),
                descriptor: .init(
                    name: name, summary: "", inputSchema: .object([:]), target: .local, approvalPolicy: .approve),
                state: .completed, result: .init(callID: "call", content: value.encodedString))
            return try #require(ResourceToolCardPresentation.content(for: card, locale: Locale(identifier: "en")))
        }
        func measure(_ content: ResourceToolCardContent, expanded: Bool, width: CGFloat, largeType: Bool) -> CGSize {
            let controller = UIHostingController(
                rootView:
                    ResourceToolCardView(content: content, expanded: .constant(expanded))
                    .environment(\.dynamicTypeSize, largeType ? .accessibility3 : .large))
            return controller.sizeThatFits(in: CGSize(width: width, height: 10_000))
        }
        let short = try card(100)
        let long = try card(5_000)
        for width in [CGFloat(280), CGFloat(700)] {
            for expanded in [false, true] {
                for largeType in [false, true] {
                    let first = measure(short, expanded: expanded, width: width, largeType: largeType)
                    let second = measure(long, expanded: expanded, width: width, largeType: largeType)
                    #expect(first.height > 0)
                    #expect(second.width <= width)
                    #expect(abs(first.height - second.height) < 1)
                }
            }
        }
    }

    @Test func sharedCatalogUsesTheMobileLibraryAndGatesMutationsToActing() async throws {
        let app = try MobileAppModel(inMemory: true)
        let connections = AgentConnectionPool(
            configuration: { _ in throw TestFailure.unused },
            routeFingerprint: { _ in throw TestFailure.unused },
            openConnection: { _ in throw TestFailure.unused },
            openSFTP: { _ in throw TestFailure.unused }, sweepInterval: nil)
        let tools = TermindAgentTools.tools(
            in: .init(
                hosts: AgentHostResolver(store: app.library), metrics: app.metrics.core,
                connections: connections, management: app.resourceManagement))
        let names = tools.map(\.descriptor.name)
        #expect(Set(names).isSuperset(of: TermindToolName.managementNames))
        #expect(names.filter { $0 == TermindToolName.listHosts }.count == 1)
        #expect(names.filter { $0 == TermindToolName.getMetrics }.count == 1)
        for tool in tools
        where TermindToolName.managementNames.contains(tool.descriptor.name)
            && tool.descriptor.name != TermindToolName.runSnippet
        {
            #expect(
                tool.availableIn.contains(.planning)
                    == TermindToolName.managementReadOnlyNames.contains(tool.descriptor.name))
        }
        let add = try #require(tools.first { $0.descriptor.name == TermindToolName.addSnippetPackage })
        let invocation = AgentToolInvocation(
            runID: UUID(),
            call: .init(
                id: "add", name: add.descriptor.name,
                arguments: .object(["name": .string("Mobile scripts")])))
        let result = try await add.execute(
            invocation,
            context: .init(
                runID: invocation.runID, userIntent: "Create snippet package", secretBroker: SecretBroker(),
                userInteraction: UnavailableAgentUserInteraction(), preflightMetadata: [:], authorize: { _ in .allow }))
        #expect(!result.isError)
        #expect(app.library.snippetPackages.contains { $0.name == "Mobile scripts" })
    }

    private enum TestFailure: Error { case unused }
}
