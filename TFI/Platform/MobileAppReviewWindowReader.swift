import SwiftUI
import TermindApplication
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Observes one UIKit window without consuming input. SwiftUI owns navigation;
/// this adapter owns native focus, presentations, pointer input, and key presses.
struct MobileAppReviewWindowReader: UIViewRepresentable {
    let controller: AppReviewController
    let surfaceID: UUID
    let location: AppReviewController.Location
    let sceneIsActive: Bool
    let isBlocked: Bool
    let request: () -> Void

    func makeUIView(context: Context) -> MobileReviewActivityView {
        MobileReviewActivityView(controller: controller, surfaceID: surfaceID)
    }

    func updateUIView(_ view: MobileReviewActivityView, context: Context) {
        view.location = location
        view.sceneIsActive = sceneIsActive
        view.isBlocked = isBlocked
        view.request = request
        view.refresh()
    }

    static func dismantleUIView(_ view: MobileReviewActivityView, coordinator: ()) {
        view.stop()
    }
}

final class MobileReviewActivityView: UIView, UIGestureRecognizerDelegate {
    private let controller: AppReviewController
    private let surfaceID: UUID
    var location: AppReviewController.Location = .other
    var sceneIsActive = false
    var isBlocked = false
    var request: () -> Void = {}
    private weak var observedWindow: UIWindow?
    private var observers: [any NSObjectProtocol] = []
    private var inputRecognizer: ReviewInteractionGestureRecognizer?
    private var hoverRecognizer: UIHoverGestureRecognizer?
    private var timer: Timer?

    init(controller: AppReviewController, surfaceID: UUID) {
        self.controller = controller
        self.surfaceID = surfaceID
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit { stop() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window !== observedWindow else {
            refresh()
            return
        }
        detach(removeSurface: false)
        guard let window else {
            controller.removeSurface(surfaceID)
            return
        }
        observedWindow = window
        if window.isKeyWindow, MobileReviewSurfaceFocus.activeSurfaceID == nil {
            MobileReviewSurfaceFocus.activeSurfaceID = surfaceID
        }
        installInputObservers(on: window)
        installLifecycleObservers(on: window)
        refresh()
    }

    func refresh() {
        let available =
            sceneIsActive
            && observedWindow?.windowScene?.activationState == .foregroundActive
            && observedWindow?.isKeyWindow == true
            && observedWindow?.isHidden == false
        if available, MobileReviewSurfaceFocus.activeSurfaceID == nil {
            MobileReviewSurfaceFocus.activeSurfaceID = surfaceID
        }
        let active = available && MobileReviewSurfaceFocus.activeSurfaceID == surfaceID
        controller.update(
            surfaceID: surfaceID,
            context: .init(
                location: location,
                isActive: active,
                isBlocked: isBlocked || observedWindow?.rootViewController?.presentedViewController != nil
            )
        )
        if active {
            if timer == nil {
                let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
                timer.tolerance = 0.1
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
            controller.requestIfReady(surfaceID: surfaceID, request: request)
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    func stop() {
        detach(removeSurface: true)
    }

    private func installInputObservers(on window: UIWindow) {
        let input = ReviewInteractionGestureRecognizer { [weak self] in self?.recordInteraction() }
        input.delegate = self
        input.cancelsTouchesInView = false
        input.delaysTouchesBegan = false
        input.delaysTouchesEnded = false
        window.addGestureRecognizer(input)
        inputRecognizer = input

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(recordInteraction))
        hover.delegate = self
        hover.cancelsTouchesInView = false
        window.addGestureRecognizer(hover)
        hoverRecognizer = hover
    }

    private func installLifecycleObservers(on window: UIWindow) {
        for name in [UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if name == UIWindow.didBecomeKeyNotification {
                            MobileReviewSurfaceFocus.activeSurfaceID = self.surfaceID
                        } else {
                            MobileReviewSurfaceFocus.remove(self.surfaceID)
                        }
                        self.refresh()
                    }
                }
            )
        }
        if let windowScene = window.windowScene {
            for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification] {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: windowScene, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            if name == UIScene.didActivateNotification {
                                MobileReviewSurfaceFocus.activeSurfaceID = self.surfaceID
                            } else {
                                MobileReviewSurfaceFocus.remove(self.surfaceID)
                            }
                            self.refresh()
                        }
                    }
                )
            }
        }
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            )
        }
    }

    private func detach(removeSurface: Bool) {
        timer?.invalidate()
        timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let inputRecognizer { observedWindow?.removeGestureRecognizer(inputRecognizer) }
        if let hoverRecognizer { observedWindow?.removeGestureRecognizer(hoverRecognizer) }
        inputRecognizer = nil
        hoverRecognizer = nil
        observedWindow = nil
        if removeSurface {
            MobileReviewSurfaceFocus.remove(surfaceID)
            controller.removeSurface(surfaceID)
        }
    }

    @objc private func recordInteraction() {
        MobileReviewSurfaceFocus.activeSurfaceID = surfaceID
        controller.recordInteraction(surfaceID: surfaceID)
        refresh()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

@MainActor
private enum MobileReviewSurfaceFocus {
    static var activeSurfaceID: UUID?

    static func remove(_ surfaceID: UUID) {
        if activeSurfaceID == surfaceID { activeSurfaceID = nil }
    }
}

private final class ReviewInteractionGestureRecognizer: UIGestureRecognizer {
    private let interaction: () -> Void

    init(interaction: @escaping () -> Void) {
        self.interaction = interaction
        super.init(target: nil, action: nil)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        interaction()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        interaction()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        interaction()
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        interaction()
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        state = .failed
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}
