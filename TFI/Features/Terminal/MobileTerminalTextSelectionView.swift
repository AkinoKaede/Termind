import GhosttyTerminal
import SwiftUI
import TermindPresentation
import UIKit

struct MobileTerminalTextSelection: Identifiable {
    let id = UUID()
    let text: String
    let anchorRange: NSRange?

    init(text: String, anchorRange: NSRange?) {
        self.text = text
        self.anchorRange = anchorRange
    }

    init(_ request: TerminalTextSelectionRequest) {
        self.init(text: request.text, anchorRange: request.anchorRange)
    }
}

struct MobileTerminalTextSelectionView: UIViewControllerRepresentable {
    let selection: MobileTerminalTextSelection
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = MobileTerminalTextSelectionViewController(selection: selection)
        controller.onDone = context.coordinator.dismiss
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_: UINavigationController, context _: Context) {}

    final class Coordinator {
        let dismiss: () -> Void

        init(dismiss: DismissAction) {
            self.dismiss = { dismiss() }
        }
    }
}

@MainActor
final class MobileTerminalTextSelectionViewController: UIViewController {
    let selection: MobileTerminalTextSelection
    var onDone: (() -> Void)?

    private(set) lazy var textView: UITextView = {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.backgroundColor = .clear
        view.textColor = .label
        view.textContainerInset = .init(top: 12, left: 12, bottom: 12, right: 12)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    init(selection: MobileTerminalTextSelection) {
        self.selection = selection
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: AppStrings.Terminal.selectText)
        view.backgroundColor = .clear
        textView.text = selection.text
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(done)
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.view.backgroundColor = .clear
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        navigationController?.navigationBar.standardAppearance = appearance
        navigationController?.navigationBar.scrollEdgeAppearance = appearance
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
        let range = Self.resolvedSelectionRange(text: selection.text, anchorRange: selection.anchorRange)
        textView.selectedRange = range
        textView.scrollRangeToVisible(range)
    }

    static func resolvedSelectionRange(text: String, anchorRange: NSRange?) -> NSRange {
        let length = (text as NSString).length
        guard let anchorRange,
            anchorRange.location != NSNotFound,
            anchorRange.location <= length,
            anchorRange.length <= length - anchorRange.location
        else {
            return NSRange(location: 0, length: length)
        }
        return anchorRange
    }

    @objc private func done() {
        onDone?()
    }
}
