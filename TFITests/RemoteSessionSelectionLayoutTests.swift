import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit

import struct TermindDomain.Host

@Suite @MainActor
struct RemoteSessionSelectionLayoutTests {
    @Test
    func longJourneyTitlesGrowVerticallyOnNarrowScreens() {
        func height(title: String, width: CGFloat) -> CGFloat {
            let host = Host(name: title, host: "server.invalid")
            let journey = ConnectionJourney()
            journey.begin(host: host, route: [host], purpose: .sshSession, username: "user")
            let controller = UIHostingController(rootView: ConnectionJourneyHeader(journey: journey) {})
            return controller.sizeThatFits(in: CGSize(width: width, height: 10_000)).height
        }

        let title = "Production Application Server With a Long Descriptive Host Name"
        #expect(height(title: title, width: 320) > height(title: "Server", width: 320))
        #expect(height(title: title, width: 320) > height(title: title, width: 768))
    }

    @Test(arguments: ["en", "de", "zh-Hans"])
    func sessionFormExpandsInsteadOfClippingAtAccessibilitySizes(language: String) async throws {
        let coordinator = RemoteSessionCoordinator()
        let task = Task { try? await coordinator.confirmPlainConnection() }
        defer {
            coordinator.cancel()
            task.cancel()
        }
        for _ in 0..<100 {
            if coordinator.prompt != nil { break }
            await Task.yield()
        }
        _ = try #require(coordinator.prompt)

        func height(typeSize: DynamicTypeSize) -> CGFloat {
            let controller = UIHostingController(
                rootView: RemoteSessionPromptView(coordinator: coordinator, cancel: {})
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.dynamicTypeSize, typeSize)
                    .frame(width: 264))
            return controller.sizeThatFits(in: CGSize(width: 264, height: 10_000)).height
        }

        #expect(height(typeSize: .accessibility3) > height(typeSize: .large))
    }
}
