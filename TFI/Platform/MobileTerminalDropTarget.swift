import UIKit

/// Routes file drops to the workspace while retaining Ghostty's text/URL drop behavior.
/// The original interaction is restored when the workspace destination is detached.
@MainActor
final class MobileTerminalDropTarget: NSObject, UIDropInteractionDelegate {
    private weak var view: UIView?
    private weak var uploadDelegate: (any UIDropInteractionDelegate)?
    private let original: UIDropInteraction
    private lazy var interaction = UIDropInteraction(delegate: self)

    init?(view: UIView, uploadDelegate: any UIDropInteractionDelegate) {
        // Navigation can reattach a retained terminal before the old SwiftUI
        // destination is dismantled. Never wrap another workspace's forwarder.
        for interaction in view.interactions.compactMap({ $0 as? UIDropInteraction }) {
            (interaction.delegate as? MobileTerminalDropTarget)?.uninstall()
        }
        guard let original = view.interactions.compactMap({ $0 as? UIDropInteraction }).first else { return nil }
        self.view = view
        self.uploadDelegate = uploadDelegate
        self.original = original
        super.init()
        view.removeInteraction(original)
        view.addInteraction(interaction)
    }

    func uninstall() {
        guard let view, interaction.view === view else { return }
        view.removeInteraction(interaction)
        view.addInteraction(original)
        self.view = nil
        uploadDelegate = nil
    }

    private func delegate(for session: any UIDropSession) -> (any UIDropInteractionDelegate)? {
        MobileDropPayloadLoader.acceptsUpload(session.items.map(\.itemProvider)) ? uploadDelegate : original.delegate
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        delegate(for: session)?.dropInteraction?(interaction, canHandle: session) ?? false
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: any UIDropSession) {
        delegate(for: session)?.dropInteraction?(interaction, sessionDidEnter: session)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession)
        -> UIDropProposal
    {
        delegate(for: session)?.dropInteraction?(interaction, sessionDidUpdate: session)
            ?? UIDropProposal(operation: .cancel)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
        delegate(for: session)?.dropInteraction?(interaction, sessionDidExit: session)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) {
        delegate(for: session)?.dropInteraction?(interaction, sessionDidEnd: session)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        delegate(for: session)?.dropInteraction?(interaction, performDrop: session)
    }

    func dropInteraction(_ interaction: UIDropInteraction, concludeDrop session: any UIDropSession) {
        delegate(for: session)?.dropInteraction?(interaction, concludeDrop: session)
    }
}
