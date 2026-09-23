import SwiftUI
import TermindPresentation
import UIKit

/// The workspace owns presentation intent; the edit service owns the local file.
@MainActor
final class MobileSFTPOpenWithPresenter: NSObject, UIDocumentInteractionControllerDelegate {
    weak var sourceView: UIView?
    var failed: (String) -> Void = { _ in }
    var finished: () -> Void = {}
    var isEnabled = false {
        didSet { if !isEnabled { invalidate() } }
    }
    private var requestID: UUID?
    private(set) var controller: UIDocumentInteractionController?
    private var sending = false
    private var handoffRetention: MobileSFTPOpenWithPresenter?
    private let present: @MainActor (UIDocumentInteractionController, UIView) -> Bool

    init(
        present: @escaping @MainActor (UIDocumentInteractionController, UIView) -> Bool = { controller, view in
            controller.presentOpenInMenu(
                from: CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1),
                in: view, animated: true)
        }
    ) {
        self.present = present
    }

    func begin() -> UUID? {
        guard isEnabled, !sending else { return nil }
        invalidate()
        let id = UUID()
        requestID = id
        return id
    }

    func downloaded(_ url: URL, request: UUID) {
        guard requestID == request else { return }
        requestID = nil
        guard isEnabled, let sourceView, sourceView.window != nil else { return }
        let controller = UIDocumentInteractionController(url: url)
        controller.delegate = self
        self.controller = controller
        if !present(controller, sourceView) {
            self.controller = nil
            failed(String(localized: AppStrings.SFTP.noInstalledAppCanOpenThisFile))
        }
    }

    func invalidate() {
        requestID = nil
        // Switching to the receiving app can deactivate this scene before handoff finishes.
        guard !sending else { return }
        let previous = controller
        controller = nil
        previous?.dismissMenu(animated: false)
    }

    func documentInteractionController(
        _ controller: UIDocumentInteractionController, willBeginSendingToApplication application: String?
    ) {
        guard self.controller === controller else { return }
        sending = true
        handoffRetention = self
    }

    func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
        guard self.controller === controller, !sending else { return }
        self.controller = nil
        finished()
    }

    func documentInteractionController(
        _ controller: UIDocumentInteractionController, didEndSendingToApplication application: String?
    ) {
        guard self.controller === controller else { return }
        sending = false
        self.controller = nil
        finished()
        handoffRetention = nil
    }
}

struct MobileSFTPOpenWithAnchor: UIViewRepresentable {
    let presenter: MobileSFTPOpenWithPresenter
    let isEnabled: Bool
    let failed: (String) -> Void
    let finished: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        presenter.sourceView = view
        presenter.failed = failed
        presenter.finished = finished
        presenter.isEnabled = isEnabled
    }
}
