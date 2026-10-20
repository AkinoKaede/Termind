// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import UIKit

/// Uses the window for native drop routing, with a non-interactive view marking
/// the visible workspace's bounds. A terminal's own interaction forwards here too.
struct MobileWindowDropTarget: UIViewRepresentable {
    @Binding var isTargeted: Bool
    let isEnabled: Bool
    let terminalView: UIView?
    let receive: ([NSItemProvider]) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, targeted: setTargeted, receive: receive)
    }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: InstallerView, context: Context) {
        context.coordinator.receive = receive
        context.coordinator.targeted = setTargeted
        context.coordinator.isEnabled = isEnabled
        view.coordinator = context.coordinator
        context.coordinator.install(in: view, terminalView: terminalView)
    }

    static func dismantleUIView(_ view: InstallerView, coordinator: Coordinator) {
        coordinator.uninstall()
        view.coordinator = nil
    }

    private func setTargeted(_ value: Bool) {
        isTargeted = value
    }

    final class InstallerView: UIView {
        weak var coordinator: Coordinator?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.moveToWindow()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIDropInteractionDelegate {
        var receive: ([NSItemProvider]) -> Bool
        var targeted: (Bool) -> Void
        var isEnabled: Bool {
            didSet {
                if !isEnabled { clearTarget() }
            }
        }

        private weak var region: UIView?
        private weak var installedWindow: UIWindow?
        private weak var terminalView: UIView?
        private var terminalDropTarget: MobileTerminalDropTarget?
        private lazy var interaction = UIDropInteraction(delegate: self)
        private weak var activeInteraction: UIDropInteraction?
        private weak var performedSession: (any UIDropSession)?
        private var isTargeted = false

        init(isEnabled: Bool, targeted: @escaping (Bool) -> Void, receive: @escaping ([NSItemProvider]) -> Bool) {
            self.isEnabled = isEnabled
            self.targeted = targeted
            self.receive = receive
        }

        func install(in region: UIView, terminalView: UIView? = nil) {
            self.region = region
            if self.terminalView !== terminalView {
                terminalDropTarget?.uninstall()
                terminalDropTarget = nil
                self.terminalView = terminalView
            }
            moveToWindow()
        }

        func moveToWindow() {
            let window = region?.window
            if installedWindow !== window {
                clearTarget()
                installedWindow?.removeInteraction(interaction)
                installedWindow = window
                window?.addInteraction(interaction)
                terminalDropTarget?.uninstall()
                terminalDropTarget = nil
            }
            if window != nil, terminalDropTarget == nil, let terminalView {
                terminalDropTarget = MobileTerminalDropTarget(view: terminalView, uploadDelegate: self)
            }
        }

        func uninstall() {
            clearTarget()
            installedWindow?.removeInteraction(interaction)
            terminalDropTarget?.uninstall()
            terminalDropTarget = nil
            installedWindow = nil
            terminalView = nil
            region = nil
        }

        private var isVisible: Bool {
            guard isEnabled, let region, let window = installedWindow, region.window === window,
                !region.bounds.isEmpty, !hasPresentation(in: window.rootViewController)
            else { return false }
            var ancestor: UIView? = region
            while let view = ancestor {
                if view.isHidden || view.alpha <= 0.01 { return false }
                ancestor = view.superview
            }
            return true
        }

        private func hasPresentation(in controller: UIViewController?) -> Bool {
            guard let controller else { return false }
            return controller.presentedViewController != nil || controller.children.contains { hasPresentation(in: $0) }
        }

        private func accepts(_ session: any UIDropSession, atLocation: Bool) -> Bool {
            guard isVisible, MobileDropPayloadLoader.acceptsUpload(session.items.map(\.itemProvider)), let region else {
                return false
            }
            return !atLocation || region.bounds.contains(session.location(in: region))
        }

        private func updateTarget(_ value: Bool, interaction: UIDropInteraction) {
            if value {
                activeInteraction = interaction
            } else if activeInteraction !== interaction {
                return
            }
            if isTargeted != value {
                isTargeted = value
                targeted(value)
            }
        }

        private func clearTarget() {
            activeInteraction = nil
            if isTargeted {
                isTargeted = false
                targeted(false)
            }
        }

        func dropInteraction(_: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
            accepts(session, atLocation: false)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: any UIDropSession) {
            updateTarget(accepts(session, atLocation: true), interaction: interaction)
        }

        func dropInteraction(
            _ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession
        ) -> UIDropProposal {
            let accepted = accepts(session, atLocation: true)
            updateTarget(accepted, interaction: interaction)
            return UIDropProposal(operation: accepted ? .copy : .cancel)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit _: any UIDropSession) {
            updateTarget(false, interaction: interaction)
        }

        func dropInteraction(_: UIDropInteraction, sessionDidEnd _: any UIDropSession) {
            clearTarget()
        }

        func dropInteraction(_: UIDropInteraction, performDrop session: any UIDropSession) {
            clearTarget()
            guard accepts(session, atLocation: true), performedSession !== session else { return }
            performedSession = session
            _ = receive(session.items.map(\.itemProvider))
        }
    }
}
