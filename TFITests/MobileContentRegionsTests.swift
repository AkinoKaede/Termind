import SwiftUI
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileContentRegionsTests {
    @MainActor @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
    func nativePanesMirrorWithLayoutDirectionWithoutChangingTheirFramesOrIdentity(direction: LayoutDirection)
        async throws
    {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let first = UIView()
        let second = UIView()
        let controller = UIHostingController(
            rootView:
                MobilePaneLayout(frames: [
                    CGRect(x: 0, y: 0, width: 390, height: 600),
                    CGRect(x: 430, y: 0, width: 390, height: 600),
                ]) {
                    NativePane(view: first)
                    NativePane(view: second)
                }
                .environment(\.layoutDirection, direction))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(200))
        let firstFrame = first.convert(first.bounds, to: controller.view)
        let secondFrame = second.convert(second.bounds, to: controller.view)
        #expect(first.bounds.size == CGSize(width: 390, height: 600))
        #expect(second.bounds.size == first.bounds.size)
        #expect((firstFrame.minX < secondFrame.minX) == (direction == .leftToRight))
        #expect(abs(firstFrame.minX - secondFrame.minX) == 430)
    }

    @Test func workspaceTabsFollowTopAndVerticalBarsAndHideWhenReturningToTheBottom() {
        #expect(!MobileToolbarLayout().showsWorkspaceTabs)
        #expect(MobileToolbarLayout(isTopBar: true).showsWorkspaceTabs)
        for edge in [HorizontalEdge.leading, .trailing] {
            var layout = MobileToolbarLayout(verticalEdge: edge)
            #expect(layout.showsWorkspaceTabs)
            #expect(layout.usesIconSwitcher)
            layout.verticalEdge = nil
            #expect(!layout.showsWorkspaceTabs)
            #expect(!layout.usesIconSwitcher)
        }
        #expect(MobileToolbarLayout(isTopBar: true).usesIconSwitcher)
    }

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

private struct NativePane: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
