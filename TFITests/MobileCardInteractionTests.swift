// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized, .requiresKeyWindow) @MainActor
struct MobileCardInteractionTests {
    @Test(arguments: [false, true])
    func standardAndCompactCardsRetainNativeMenusAndDragPayloads(compact: Bool) async throws {
        let cards = (0..<6).map { _ in CardItem() }
        let scope = UUID()
        var moves = 0
        var frames: [UUID: CGRect] = [:]
        let controller = UIHostingController(
            rootView: MobileReorderableCardGrid(
                items: cards, compact: compact,
                reordering: MobileCardReordering(collection: .hosts, allowedIDs: Set(cards.map(\.id))),
                move: { _, _ in moves += 1 }
            ) { item in
                MobileActionCard(compact: compact, action: {}) {
                    if compact {
                        MobileCompactCardContent(title: item.id.uuidString, status: Text("Ready")) {
                            MobileCardIcon(symbol: "server.rack", tint: .blue)
                        }
                    } else {
                        Text(item.id.uuidString)
                    }
                } actions: {
                    Button(AppStrings.Common.edit.swiftUIKey, systemImage: "pencil") {}
                }
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    frames[item.id] = $0
                }
            }
            .environment(\.mobileCardReorderScope, scope)
            .dynamicTypeSize(.large)
            .padding(16))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        for _ in 0..<10 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        // SwiftUI can multiplex all cards through one hosting-view interaction.
        let interactions = descendants(controller.view).flatMap(\.interactions)
        let drag = try #require(interactions.compactMap { $0 as? UIDragInteraction }.first)
        let surface = try #require(drag.view)
        let menu = try #require(surface.interactions.compactMap { $0 as? UIContextMenuInteraction }.first)
        #expect(drag.isEnabled)
        let gridWidth = controller.view.safeAreaLayoutGuide.layoutFrame.width - 32
        let columns = MobileCardLayout.columns(width: gridWidth, accessibilitySize: false, compact: compact)
        let expectedWidth = (gridWidth - CGFloat(columns - 1) * 12) / CGFloat(columns)
        for card in cards {
            let frame = try #require(frames[card.id])
            #expect(abs(frame.width - expectedWidth) < 1)
            let point = CGPoint(x: frame.midX, y: frame.midY)
            let menuConfiguration = menu.delegate?.contextMenuInteraction(
                menu, configurationForMenuAtLocation: surface.convert(point, from: controller.view))
            #expect(menuConfiguration != nil)
            let session = CardDragSession(root: controller.view, point: point)
            let items = try #require(drag.delegate).dragInteraction(drag, itemsForBeginning: session)
            let item = try #require(items.first)
            let payload: MobileCardDragItem = try await withCheckedThrowingContinuation { continuation in
                _ = item.itemProvider.loadTransferable(type: MobileCardDragItem.self) {
                    continuation.resume(with: $0)
                }
            }
            #expect(payload.id == card.id)
            #expect(payload.scope == scope)
            #expect(payload.collection == .hosts)
            #expect(!MobileDropPayloadLoader.acceptsUpload([item.itemProvider]))
            // Lifting and cancelling must not invoke a persistence operation.
            drag.delegate?.dragInteraction?(drag, session: session, didEndWith: .cancel)
            #expect(moves == 0)
        }
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

private struct CardItem: Identifiable {
    let id = UUID()
}

private final class CardDragSession: NSObject, UIDragSession {
    var items: [UIDragItem] = []
    var localContext: Any?
    let allowsMoveOperation = true
    let isRestrictedToDraggingApplication = true
    let root: UIView
    let point: CGPoint

    init(root: UIView, point: CGPoint) {
        self.root = root
        self.point = point
    }

    func location(in view: UIView) -> CGPoint { view.convert(point, from: root) }
    func hasItemsConforming(toTypeIdentifiers identifiers: [String]) -> Bool {
        items.contains { item in identifiers.contains { item.itemProvider.hasItemConformingToTypeIdentifier($0) } }
    }
    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool {
        items.contains { $0.itemProvider.canLoadObject(ofClass: aClass) }
    }
}
