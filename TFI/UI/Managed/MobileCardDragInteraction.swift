// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Non-interactive markers leave taps and SwiftUI context menus on the original card surfaces.
struct MobileCardDragRegion: UIViewRepresentable {
    let session: MobileCardReorderSession
    let section: MobileCardSectionID
    let target: UUID?
    let orderedIDs: [UUID]
    let reordering: MobileCardReordering
    let preview: AnyView?
    let move: (UUID, UUID?) -> Void

    func makeUIView(context: Context) -> RegionView { RegionView() }

    func updateUIView(_ view: RegionView, context: Context) {
        view.configuration = self
        session.interaction.register(view)
    }

    static func dismantleUIView(_ view: RegionView, coordinator: ()) {
        view.configuration?.session.interaction.unregister(view)
        view.configuration = nil
    }

    final class RegionView: UIView {
        var configuration: MobileCardDragRegion?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { configuration?.session.interaction.register(self) }
        }
    }
}

/// Owns the native session lifecycle so cancellation outside the grid also rolls back the draft.
@MainActor
final class MobileCardDragInteraction: NSObject, UIDragInteractionDelegate, UIDropInteractionDelegate {
    private weak var owner: MobileCardReorderSession?
    private let regions = NSHashTable<MobileCardDragRegion.RegionView>.weakObjects()
    private weak var scrollView: UIScrollView?
    private lazy var drag = UIDragInteraction(delegate: self)
    private lazy var drop = UIDropInteraction(delegate: self)
    private var source: MobileCardDragRegion?
    private var sourceFrame = CGRect.zero
    private var previewImage: UIImage?
    private var landingFrame: CGRect?
    private var lastPlacementPoint: CGPoint?
    private var locationInWindow: CGPoint?
    private var displayLink: CADisplayLink?
    private let liftFeedback = UIImpactFeedbackGenerator(style: .soft)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let dropFeedback = UIImpactFeedbackGenerator(style: .light)
    private lazy var scrollTick = ScrollTick(owner: self)

    init(owner: MobileCardReorderSession) { self.owner = owner }

    func register(_ region: MobileCardDragRegion.RegionView) {
        regions.add(region)
        var ancestor = region.superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                if scrollView !== scroll {
                    uninstall()
                    scrollView = scroll
                    drag.isEnabled = true
                    scroll.addInteraction(drag)
                    scroll.addInteraction(drop)
                }
                return
            }
            ancestor = view.superview
        }
    }

    func reinstall() {
        for region in regions.allObjects where region.window != nil { register(region) }
    }

    func unregister(_ region: MobileCardDragRegion.RegionView) { regions.remove(region) }

    func uninstall() {
        finish()
        scrollView?.removeInteraction(drag)
        scrollView?.removeInteraction(drop)
        scrollView = nil
    }

    private func visibleRegions() -> [MobileCardDragRegion.RegionView] {
        regions.allObjects.filter { region in
            guard region.window != nil, !region.bounds.isEmpty else { return false }
            var ancestor: UIView? = region
            while let view = ancestor {
                if view.isHidden || view.alpha <= 0.01 { return false }
                ancestor = view.superview
            }
            return true
        }
    }

    private func region(at point: CGPoint) -> MobileCardDragRegion.RegionView? {
        guard let scrollView else { return nil }
        return visibleRegions().filter { $0.convert($0.bounds, to: scrollView).insetBy(dx: -6, dy: -6).contains(point) }
            .min {
                let first = $0.convert($0.bounds, to: scrollView)
                let second = $1.convert($1.bounds, to: scrollView)
                return hypot(first.midX - point.x, first.midY - point.y)
                    < hypot(second.midX - point.x, second.midY - point.y)
            }
    }

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem]
    {
        guard let owner, owner.payload == nil, let scrollView,
            let region = region(at: session.location(in: scrollView)),
            let configuration = region.configuration, let id = configuration.target,
            configuration.reordering.allowedIDs.contains(id), let content = configuration.preview
        else { return [] }
        let frame = region.convert(region.bounds, to: scrollView)
        let renderer = ImageRenderer(
            content:
                content
                .environment(\.mobileCardIsDragPreview, true)
                .environment(\.colorScheme, scrollView.traitCollection.userInterfaceStyle == .dark ? .dark : .light)
                .frame(width: frame.width, height: frame.height))
        renderer.scale = scrollView.window?.screen.scale ?? 2
        guard let rendered = renderer.uiImage else { return [] }
        // ImageRenderer can omit root-view opacity; bake translucency into the preview pixels.
        let format = UIGraphicsImageRendererFormat()
        format.scale = renderer.scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: frame.size, format: format).image { _ in
            rendered.draw(in: CGRect(origin: .zero, size: frame.size), blendMode: .normal, alpha: 0.92)
        }
        let payload = MobileCardDragItem(id: id, scope: owner.scope, collection: configuration.section.collection)
        guard let data = try? JSONEncoder().encode(payload) else { return [] }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.mobileCardOrder.identifier, visibility: .ownProcess
        ) {
            completion in
            completion(data, nil)
            return nil
        }
        let item = UIDragItem(itemProvider: provider)
        item.localObject = payload
        item.previewProvider = { [weak self] in
            guard let self, let preview = self.preview(at: self.sourceFrame) else { return nil }
            return UIDragPreview(view: preview.view, parameters: self.previewParameters(bounds: preview.view.bounds))
        }
        liftFeedback.prepare()
        source = configuration
        sourceFrame = frame
        previewImage = image
        landingFrame = nil
        lastPlacementPoint = nil
        return [item]
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: any UIDragSession) {
        guard let owner, let source, let id = source.target else { return }
        owner.begin(id: id, section: source.section, orderedIDs: source.orderedIDs, size: sourceFrame.size)
        liftFeedback.impactOccurred(intensity: 0.65)
        selectionFeedback.prepare()
        dropFeedback.prepare()
        let link = CADisplayLink(target: scrollTick, selector: #selector(ScrollTick.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionAllowsMoveOperation session: any UIDragSession)
        -> Bool
    {
        true
    }

    func dragInteraction(
        _ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: any UIDragSession
    ) -> Bool { true }

    func dragInteraction(
        _ interaction: UIDragInteraction, prefersFullSizePreviewsFor session: any UIDragSession
    ) -> Bool { true }

    func dragInteraction(
        _ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: any UIDragSession
    ) -> UITargetedDragPreview? { preview(at: sourceFrame) }

    func dragInteraction(
        _ interaction: UIDragInteraction, previewForCancelling item: UIDragItem,
        withDefault defaultPreview: UITargetedDragPreview
    ) -> UITargetedDragPreview? {
        animate { owner?.cancel() }
        return preview(at: sourceFrame)
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionDidMove session: any UIDragSession) {
        guard let window = scrollView?.window else { return }
        locationInWindow = session.location(in: window)
    }

    func dragInteraction(
        _ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation
    ) { finish() }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        guard let owner, let payload = owner.payload, session.localDragSession != nil, session.items.count == 1,
            let item = session.items.first?.localObject as? MobileCardDragItem
        else { return false }
        return item.id == payload.id && item.scope == owner.scope && item.collection == payload.collection
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession)
        -> UIDropProposal
    {
        guard dropInteraction(interaction, canHandle: session), let scrollView else {
            return UIDropProposal(operation: .cancel)
        }
        if let window = scrollView.window { locationInWindow = session.location(in: window) }
        let accepted = updatePlacement(at: session.location(in: scrollView))
        return UIDropProposal(operation: accepted ? .move : .cancel)
    }

    @discardableResult
    private func updatePlacement(at point: CGPoint) -> Bool {
        guard let owner, let payload = owner.payload, let region = region(at: point),
            let configuration = region.configuration,
            configuration.section.collection == payload.collection,
            configuration.reordering.allowedIDs.contains(payload.id)
        else { return false }
        if configuration.target == payload.id { return true }
        // Layout movement alone must not repeatedly reorder under a stationary finger.
        if let lastPlacementPoint, hypot(point.x - lastPlacementPoint.x, point.y - lastPlacementPoint.y) < 8 {
            return true
        }
        let ids = owner.projectedIDs(configuration.orderedIDs, in: configuration.section)
        guard
            let request = configuration.reordering.resolve(
                [payload], scope: owner.scope, target: configuration.target, orderedIDs: ids
            )
        else { return true }
        animate {
            if owner.stage(request, in: configuration.section, move: configuration.move) {
                lastPlacementPoint = point
                selectionFeedback.selectionChanged()
                selectionFeedback.prepare()
            }
        }
        return true
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        guard dropInteraction(interaction, canHandle: session), let scrollView,
            updatePlacement(at: session.location(in: scrollView)), let owner
        else { return }
        landingFrame = visibleRegions().first {
            $0.configuration?.target == owner.payload?.id && $0.configuration?.section == owner.placement?.section
        }.map { $0.convert($0.bounds, to: scrollView) }
        animate { owner.commit() }
        dropFeedback.impactOccurred(intensity: 0.55)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction, previewForDropping item: UIDragItem,
        withDefault defaultPreview: UITargetedDragPreview
    ) -> UITargetedDragPreview? { landingFrame.flatMap { preview(at: $0) } }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
        locationInWindow = nil
    }

    private func preview(at frame: CGRect) -> UITargetedDragPreview? {
        guard let scrollView, let previewImage else { return nil }
        let image = UIImageView(image: previewImage)
        image.bounds = CGRect(origin: .zero, size: sourceFrame.size)
        return UITargetedDragPreview(
            view: image, parameters: previewParameters(bounds: image.bounds),
            target: UIDragPreviewTarget(container: scrollView, center: CGPoint(x: frame.midX, y: frame.midY)))
    }

    private func previewParameters(bounds: CGRect) -> UIDragPreviewParameters {
        let parameters = UIDragPreviewParameters()
        parameters.backgroundColor = .clear
        let outline = UIBezierPath(roundedRect: bounds, cornerRadius: MobileCardDragAppearance.cornerRadius)
        parameters.visiblePath = outline
        parameters.shadowPath = outline
        return parameters
    }

    private func animate(_ action: () -> Void) {
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : MobileCardDragAppearance.animation, action)
    }

    private func finish() {
        displayLink?.invalidate()
        displayLink = nil
        animate { owner?.cancel() }
        source = nil
        previewImage = nil
        landingFrame = nil
        locationInWindow = nil
        lastPlacementPoint = nil
    }

    fileprivate func scrollAtEdge() {
        guard owner?.payload != nil, let scrollView, let locationInWindow, let window = scrollView.window else {
            return
        }
        let point = scrollView.convert(locationInWindow, from: window)
        let bounds = scrollView.bounds.inset(by: scrollView.adjustedContentInset)
        guard point.x >= bounds.minX, point.x <= bounds.maxX else { return }
        let edge: CGFloat = 56
        let distance: CGFloat
        if point.y < bounds.minY + edge {
            distance = -min(1, (bounds.minY + edge - point.y) / edge)
        } else if point.y > bounds.maxY - edge {
            distance = min(1, (point.y - bounds.maxY + edge) / edge)
        } else {
            return
        }
        let minimum = -scrollView.adjustedContentInset.top
        let maximum = max(
            minimum, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        let interval = min(displayLink?.duration ?? (1.0 / 60.0), 1.0 / 30.0)
        let offset = min(maximum, max(minimum, scrollView.contentOffset.y + distance * 360 * interval))
        guard offset != scrollView.contentOffset.y else { return }
        scrollView.contentOffset.y = offset
        updatePlacement(at: scrollView.convert(locationInWindow, from: window))
    }

    private final class ScrollTick: NSObject {
        weak var owner: MobileCardDragInteraction?
        init(owner: MobileCardDragInteraction) { self.owner = owner }
        @objc func tick() { owner?.scrollAtEdge() }
    }
}
