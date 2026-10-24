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
        let reorderSession = MobileCardReorderSession()
        var moves = 0
        var frames: [UUID: CGRect] = [:]
        let controller = UIHostingController(
            rootView: ScrollView {
                MobileReorderableCardGrid(
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
                .padding(16)
            }
            .environment(\.mobileCardReorderSession, reorderSession)
            .dynamicTypeSize(.large))
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
        #expect(drag.view is UIScrollView)
        let menu = try #require(interactions.compactMap { $0 as? UIContextMenuInteraction }.first)
        let menuView = try #require(menu.view)
        #expect(drag.isEnabled)
        let gridWidth = controller.view.safeAreaLayoutGuide.layoutFrame.width - 32
        let columns = MobileCardLayout.columns(width: gridWidth, accessibilitySize: false, compact: compact)
        let expectedWidth = (gridWidth - CGFloat(columns - 1) * 12) / CGFloat(columns)
        for card in cards {
            let frame = try #require(frames[card.id])
            #expect(abs(frame.width - expectedWidth) < 1)
            let point = CGPoint(x: frame.midX, y: frame.midY)
            let menuConfiguration = menu.delegate?.contextMenuInteraction(
                menu, configurationForMenuAtLocation: menuView.convert(point, from: controller.view))
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
            #expect(payload.scope == reorderSession.scope)
            #expect(payload.collection == .hosts)
            #expect(!MobileDropPayloadLoader.acceptsUpload([item.itemProvider]))
            // Lifting and cancelling must not invoke a persistence operation.
            let preview = try #require(drag.delegate?.dragInteraction?(drag, previewForLifting: item, session: session))
            #expect(abs(preview.size.width - frame.width) < 1)
            #expect(abs(preview.size.height - frame.height) < 1)
            #expect(drag.delegate?.dragInteraction?(drag, prefersFullSizePreviewsFor: session) == true)
            let image = try #require((preview.view as? UIImageView)?.image?.cgImage)
            #expect(abs(try centerAlpha(image) - 0.92) < 1.0 / 255.0)
            drag.delegate?.dragInteraction?(drag, sessionWillBegin: session)
            #expect(reorderSession.payload?.id == card.id)
            drag.delegate?.dragInteraction?(drag, session: session, didEndWith: .cancel)
            #expect(reorderSession.payload == nil)
            #expect(moves == 0)
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test(arguments: [false, true])
    func nativeHoverMovesNeighborsAndReservesFoldedGroupBeforeSaving(compact: Bool) async throws {
        let cards = (0..<4).map { _ in CardItem() }
        let state = MobileCardReorderSession()
        let destination = UUID()
        let folded = UUID()
        let policy = MobileCardReordering(collection: .hosts, allowedIDs: Set(cards.map(\.id)))
        var writes: [MobileCardSectionID] = []
        let controller = UIHostingController(
            rootView: ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach([Optional<UUID>.none, destination], id: \.self) { group in
                        MobileReorderableCardGrid(
                            items: Array(group == nil ? cards.prefix(2) : cards.suffix(2)),
                            compact: compact, sectionID: group, reordering: policy,
                            move: { _, _ in writes.append(MobileCardSectionID(collection: .hosts, group: group)) }
                        ) { item in
                            MobileActionCard(compact: compact, action: {}) {
                                MobileCompactCardContent(
                                    title: item.id == cards[0].id ? "Production" : "Staging", status: Text("Ready")
                                ) {
                                    MobileCardIcon(symbol: "server.rack", tint: .blue)
                                }
                            } actions: {
                                Button("Edit") {}
                            }
                        }
                    }
                    Text("Archive").frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(
                            MobileCardDropTarget(
                                reordering: policy, sectionID: folded, isExpanded: false, compact: compact,
                                orderedIDs: [],
                                move: { _, _ in writes.append(MobileCardSectionID(collection: .hosts, group: folded)) })
                        )
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .environment(\.mobileCardReorderSession, state)
            .dynamicTypeSize(.large))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            state.interaction.uninstall()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutIfNeeded()
        let interactions = descendants(controller.view).flatMap(\.interactions)
        let drag = try #require(interactions.compactMap { $0 as? UIDragInteraction }.first)
        let drop = try #require(interactions.compactMap { $0 as? UIDropInteraction }.first)
        let delegate = state.interaction
        func frame(_ id: UUID?, group: UUID?) throws -> CGRect {
            let region = try #require(
                descendants(controller.view)
                    .compactMap { $0 as? MobileCardDragRegion.RegionView }
                    .first { $0.configuration?.target == id && $0.configuration?.section.group == group })
            return region.convert(region.bounds, to: controller.view)
        }
        func center(_ frame: CGRect) -> CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
        let original = try frame(cards[0].id, group: nil)
        let neighbor = try frame(cards[1].id, group: nil)
        for commit in [false, true] {
            let native = CardDragSession(root: controller.view, point: center(original))
            native.items = delegate.dragInteraction(drag, itemsForBeginning: native)
            let item = try #require(native.items.first)
            let preview = try #require(delegate.dragInteraction(drag, previewForLifting: item, session: native))
            #expect(preview.parameters.backgroundColor == .clear)
            #expect(preview.parameters.visiblePath?.bounds == CGRect(origin: .zero, size: original.size))
            if !commit, let image = (preview.view as? UIImageView)?.image?.pngData() {
                Attachment.record(image, named: "card-lift-\(compact ? "compact" : "standard").png")
            }
            delegate.dragInteraction(drag, sessionWillBegin: native)
            try await Task.sleep(for: .milliseconds(100))
            let dropping = CardDropSession(drag: native, point: center(try frame(cards[3].id, group: destination)))
            #expect(delegate.dropInteraction(drop, sessionDidUpdate: dropping).operation == .move)
            try await Task.sleep(for: .milliseconds(400))
            #expect(writes.isEmpty)
            let shifted = try frame(cards[1].id, group: nil)
            #expect(abs(shifted.minX - neighbor.minX) > 1 || abs(shifted.minY - neighbor.minY) > 1)
            let placement = state.placement
            for _ in 0..<5 { _ = delegate.dropInteraction(drop, sessionDidUpdate: dropping) }
            #expect(state.placement == placement)
            dropping.point = center(try frame(nil, group: folded))
            #expect(delegate.dropInteraction(drop, sessionDidUpdate: dropping).operation == .move)
            try await Task.sleep(for: .milliseconds(400))
            let slot = try frame(cards[0].id, group: folded)
            #expect(abs(slot.width - original.width) < 1)
            #expect(abs(slot.height - original.height) < 1)
            #expect(writes.isEmpty)
            if commit {
                dropping.point = center(slot)
                delegate.dropInteraction(drop, performDrop: dropping)
                delegate.dropInteraction(drop, performDrop: dropping)
                #expect(writes == [MobileCardSectionID(collection: .hosts, group: folded)])
            } else {
                let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                    controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                }
                Attachment.record(
                    try #require(image.pngData()), named: "card-hover-\(compact ? "compact" : "standard").png")
                _ = delegate.dragInteraction(drag, previewForCancelling: item, withDefault: preview)
            }
            delegate.dragInteraction(drag, session: native, didEndWith: commit ? .move : .cancel)
            try await Task.sleep(for: .milliseconds(400))
            #expect(state.payload == nil)
            #expect(try frame(cards[1].id, group: nil) == neighbor)
        }
    }

    private func centerAlpha(_ image: CGImage) throws -> Double {
        let pixel = try #require(
            image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try #require(
                CGContext(
                    data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Double(rgba[3]) / 255
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

private struct CardItem: Identifiable {
    let id = UUID()
}

private final class CardDropSession: NSObject, UIDropSession {
    let drag: CardDragSession
    var point: CGPoint
    var items: [UIDragItem] { drag.items }
    var localDragSession: (any UIDragSession)? { drag }
    let allowsMoveOperation = true
    let isRestrictedToDraggingApplication = true
    nonisolated let progress = Progress(totalUnitCount: 0)
    var progressIndicatorStyle = UIDropSessionProgressIndicatorStyle.none

    init(drag: CardDragSession, point: CGPoint) {
        self.drag = drag
        self.point = point
    }

    func location(in view: UIView) -> CGPoint { view.convert(point, from: drag.root) }
    func hasItemsConforming(toTypeIdentifiers identifiers: [String]) -> Bool {
        drag.hasItemsConforming(toTypeIdentifiers: identifiers)
    }
    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool {
        drag.canLoadObjects(ofClass: aClass)
    }
    func loadObjects(
        ofClass aClass: any NSItemProviderReading.Type,
        completion: @escaping ([any NSItemProviderReading]) -> Void
    ) -> Progress {
        completion([])
        return progress
    }
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
