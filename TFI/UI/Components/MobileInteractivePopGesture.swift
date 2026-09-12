import SwiftUI
import UIKit

/// SwiftUI disables the navigation controller's edge-pop recognizer when its
/// automatic back button is hidden. SFTP owns that button for directory
/// history, so this restores only the system edge gesture for leaving the page.
struct MobileInteractivePopGesture: UIViewControllerRepresentable {
    func makeUIViewController(context _: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context _: Context) {
        controller.installWhenAvailable()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator _: Void) {
        controller.uninstall()
    }

    @MainActor
    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var gesture: UIGestureRecognizer?
        private weak var previousDelegate: (any UIGestureRecognizerDelegate)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        func installWhenAvailable() {
            Task { @MainActor [weak self] in self?.install() }
        }

        func uninstall() {
            guard let gesture, gesture.delegate === self else { return }
            gesture.delegate = previousDelegate
            self.gesture = nil
            previousDelegate = nil
        }

        func gestureRecognizerShouldBegin(_: UIGestureRecognizer) -> Bool {
            guard let navigationController else { return false }
            return navigationController.viewControllers.count > 1
        }

        private func install() {
            guard let navigationController,
                let gesture = navigationController.interactivePopGestureRecognizer
            else { return }
            if self.gesture !== gesture {
                previousDelegate = gesture.delegate
                self.gesture = gesture
            }
            gesture.delegate = self
            gesture.isEnabled = navigationController.viewControllers.count > 1
        }
    }
}
