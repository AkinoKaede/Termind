import SwiftUI
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileContentRegionsTests {
    @Test func inactiveFoldDoesNotRemoveUsableSpace() {
        let size = CGSize(width: 800, height: 600)
        let regions = MobileContentRegions(
            size: size,
            reserved: [
                .init(
                    kind: .division, frame: CGRect(x: 390, y: 0, width: 20, height: 600),
                    isActive: false)
            ])
        #expect(regions.continuous == CGRect(origin: .zero, size: size))
        #expect(regions.split == nil)
        #expect(MobileMetricsPanels(regions: regions, page: .processes).showsBoth)
    }

    @Test func horizontalFoldSeparatesTranscriptAndControlsAndKeepsTerminalAboveTheFold() throws {
        let regions = MobileContentRegions(
            size: CGSize(width: 800, height: 620),
            reserved: [.init(kind: .division, frame: CGRect(x: 0, y: 300, width: 800, height: 20))])
        let split = try #require(regions.split)
        #expect(split.first == CGRect(x: 0, y: 0, width: 800, height: 300))
        #expect(split.second == CGRect(x: 0, y: 320, width: 800, height: 300))
        #expect(regions.continuous == split.first)
        let conversation = regions.assistant(interactionHeight: 140)
        #expect(conversation.first == split.first)
        #expect(conversation.second == CGRect(x: 0, y: 480, width: 800, height: 140))
        let metrics = MobileMetricsPanels(regions: regions, page: .status)
        #expect(metrics.status == split.first)
        #expect(metrics.processes == split.second)
    }

    @Test func verticalFoldUsesLeadingAndTrailingRegionsWithoutAddingMarginsAgain() throws {
        let regions = MobileContentRegions(
            size: CGSize(width: 820, height: 600),
            reserved: [.init(kind: .division, frame: CGRect(x: 390, y: -40, width: 40, height: 700))])
        let split = try #require(regions.split)
        #expect(split.first == CGRect(x: 0, y: 0, width: 390, height: 600))
        #expect(split.second == CGRect(x: 430, y: 0, width: 390, height: 600))
        #expect(regions.continuous == split.first)
        #expect(regions.assistant(interactionHeight: 900).second == split.second)
    }

    @Test func cameraAvoidanceFindsTheLargestRectangleRatherThanTheLargestDisjointFragment() {
        let camera = CGRect(x: 380, y: 0, width: 40, height: 40)
        let regions = MobileContentRegions(
            size: CGSize(width: 800, height: 600), reserved: [.init(kind: .occlusion, frame: camera)])
        #expect(regions.continuous == CGRect(x: 0, y: 40, width: 800, height: 560))
        #expect(regions.split == nil)
    }

    @Test func cameraIsAvoidedOnBothSidesOfTheFold() throws {
        let regions = MobileContentRegions(
            size: CGSize(width: 820, height: 600),
            reserved: [
                .init(kind: .division, frame: CGRect(x: 400, y: 0, width: 20, height: 600)),
                .init(kind: .occlusion, frame: CGRect(x: 600, y: 0, width: 30, height: 50)),
            ])
        let split = try #require(regions.split)
        #expect(split.second == CGRect(x: 420, y: 50, width: 400, height: 550))
        #expect(regions.continuous == split.first)
    }

    @Test func keyboardLeavingOneRegionFallsBackToStackedConversationAndSelectedMetricsPage() {
        let regions = MobileContentRegions(
            size: CGSize(width: 800, height: 300),
            reserved: [.init(kind: .division, frame: CGRect(x: 0, y: 280, width: 800, height: 40))])
        #expect(regions.split == nil)
        #expect(regions.continuous.height == 280)
        let conversation = regions.assistant(interactionHeight: 160)
        #expect(conversation.first.height == 120)
        #expect(conversation.second == CGRect(x: 0, y: 120, width: 800, height: 160))
        let metrics = MobileMetricsPanels(regions: regions, page: .processes)
        #expect(!metrics.showsBoth)
        #expect(metrics.status == nil)
        #expect(metrics.processes == regions.continuous)
    }

    @Test func occlusionOutsideWindowAndEmptySizesAreSafe() {
        let regions = MobileContentRegions(
            size: CGSize(width: 400, height: 300),
            reserved: [.init(kind: .occlusion, frame: CGRect(x: 500, y: 0, width: 40, height: 40))])
        #expect(regions.continuous == CGRect(x: 0, y: 0, width: 400, height: 300))
        let empty = MobileContentRegions(size: .zero, reserved: [])
        #expect(empty.continuous == .zero)
        #expect(!MobileMetricsPanels(regions: empty, page: .status).showsBoth)
        #expect(empty.assistant(interactionHeight: 200).second == .zero)
    }
}
