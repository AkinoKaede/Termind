// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindPresentation
import UIKit

extension View {
    func mobileOperationConfirmations() -> some View {
        environment(\.operationConfirmationRenderer) { request in
            AnyView(MobileOperationConfirmationPresenter(request: request))
        }
    }
}

private struct MobileOperationConfirmationPresenter: UIViewControllerRepresentable {
    let request: OperationConfirmationRequest

    func makeUIViewController(context: Context) -> ConfirmationAnchorController {
        ConfirmationAnchorController()
    }

    func updateUIViewController(_ controller: ConfirmationAnchorController, context: Context) {
        controller.update(
            title: request.title, message: request.message, isPresented: request.isPresented,
            placement: request.placement, actions: request.actions)
    }

    static func dismantleUIViewController(_ controller: ConfirmationAnchorController, coordinator: ()) {
        controller.removeAnchor()
    }
}

final class ConfirmationAnchorController: UIViewController, UIPopoverPresentationControllerDelegate {
    typealias Action = OperationConfirmationRequest.Action

    private var promptTitle = ""
    private var message: String?
    private var isPresented: Binding<Bool>?
    private var placement = OperationConfirmationPlacement.anchored
    private var actions: [Action] = []
    private weak var alert: UIAlertController?
    private var presentationTask: Task<Void, Never>?
    private var isDismissing = false

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        schedulePresentation()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let popover = alert?.popoverPresentationController { position(popover) }
    }

    func update(
        title: String, message: String?, isPresented: Binding<Bool>,
        placement: OperationConfirmationPlacement, actions: [Action]
    ) {
        promptTitle = title
        self.message = message
        self.isPresented = isPresented
        self.placement = placement
        self.actions = actions
        if !isPresented.wrappedValue {
            stop()
        } else {
            schedulePresentation()
        }
    }

    func stop() {
        presentationTask?.cancel()
        presentationTask = nil
        if let alert { dismiss(alert) {} }
    }

    func removeAnchor() {
        let presentation = isPresented
        stop()
        Task { @MainActor in presentation?.wrappedValue = false }
    }

    private func schedulePresentation() {
        guard isPresented?.wrappedValue == true, alert == nil, !isDismissing, presentationTask == nil else { return }
        presentationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            presentationTask = nil
            presentConfirmation()
        }
    }

    private func presentConfirmation() {
        guard isPresented?.wrappedValue == true, alert == nil, !isDismissing, view.window != nil else { return }
        var presenter = view.window?.rootViewController
        while let presented = presenter?.presentedViewController { presenter = presented }
        // Context menus and swipe actions must finish closing before presenting another controller.
        if let transition = presenter?.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { [weak self] _ in self?.schedulePresentation() }
            return
        }
        let alert = UIAlertController(title: promptTitle, message: message, preferredStyle: .actionSheet)
        alert.modalPresentationStyle = .popover
        for action in actions {
            // Popovers omit UIKit's cancel row. Keep Cancel as a visible, vertically stacked action.
            let style: UIAlertAction.Style = action.role == .destructive ? .destructive : .default
            alert.addAction(
                UIAlertAction(title: action.title, style: style) { [weak self, weak alert] _ in
                    guard let self, let alert else { return }
                    performAfterDismissal(action.perform, from: alert)
                })
        }
        guard let popover = alert.popoverPresentationController else { return }
        popover.delegate = self
        position(popover)
        self.alert = alert
        present(alert, animated: true)
    }

    func performAfterDismissal(_ action: @escaping () -> Void, from alert: UIAlertController) {
        dismiss(alert) { [weak self] in
            action()
            self?.isPresented?.wrappedValue = false
        }
    }

    private func dismiss(_ alert: UIAlertController, completion: @escaping () -> Void) {
        guard !isDismissing else { return }
        isDismissing = true
        let finish = { [weak self] in
            self?.alert = nil
            // Keep the source row alive until the native exit transition has finished.
            completion()
            self?.isDismissing = false
            self?.schedulePresentation()
        }
        if alert.isBeingDismissed {
            if let transition = alert.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { _ in finish() }
            } else {
                finish()
            }
        } else if alert.presentingViewController != nil {
            alert.dismiss(animated: true, completion: finish)
        } else {
            finish()
        }
    }

    private func position(_ popover: UIPopoverPresentationController) {
        switch placement {
        case .anchored:
            popover.sourceView = view
            popover.sourceRect = view.bounds
        case .centered:
            guard let window = view.window else { return }
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
        }
        popover.permittedArrowDirections = []
    }

    func adaptivePresentationStyle(
        for controller: UIPresentationController, traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle { .none }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === alert, !isDismissing else { return }
        alert = nil
        isPresented?.wrappedValue = false
    }
}
