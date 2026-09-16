import SwiftUI
import TermindPresentation
import UIKit

/// A field-scoped paste proxy; the original text-input delegate is never replaced.
struct MobileSingleLineFieldInput: UIViewRepresentable {
    final class Marker: UIView {
        private weak var field: UITextField?
        private let proxy = DelegateProxy()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleAttach()
        }

        func scheduleAttach() {
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func attach() {
            guard window != nil else {
                detach()
                return
            }
            var ancestor = superview
            while let view = ancestor {
                if let candidate = findField(in: view) {
                    guard !candidate.isSecureTextEntry else { return }
                    if let existing = candidate.pasteDelegate as? DelegateProxy, existing !== proxy { return }
                    if field !== candidate { detach() }
                    field = candidate
                    if candidate.pasteDelegate !== proxy {
                        proxy.originalDelegate = candidate.pasteDelegate
                        candidate.pasteDelegate = proxy
                    }
                    return
                }
                ancestor = view.superview
            }
        }

        private func findField(in view: UIView) -> UITextField? {
            if let field = view as? UITextField, field.convert(field.bounds, to: self).intersects(bounds) {
                return field
            }
            return view.subviews.lazy.compactMap { self.findField(in: $0) }.first
        }

        func detach() {
            if field?.pasteDelegate === proxy { field?.pasteDelegate = proxy.originalDelegate }
            field = nil
            proxy.originalDelegate = nil
        }
    }

    // NSObject's selector lookup is nonisolated; UIKit's actual paste callback stays MainActor.
    nonisolated final class DelegateProxy: NSObject, UITextPasteDelegate {
        weak var originalDelegate: (any UITextPasteDelegate)?

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if originalDelegate?.responds(to: selector) == true { return originalDelegate }
            return super.forwardingTarget(for: selector)
        }

        @MainActor
        func textPasteConfigurationSupporting(
            _ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
            combineItemAttributedStrings itemStrings: [NSAttributedString], for textRange: UITextRange
        ) -> NSAttributedString {
            let combined: NSAttributedString
            if let original = originalDelegate?.textPasteConfigurationSupporting?(
                textPasteConfigurationSupporting, combineItemAttributedStrings: itemStrings, for: textRange)
            {
                combined = original
            } else {
                let result = NSMutableAttributedString(string: "")
                for item in itemStrings { result.append(item) }
                combined = result
            }
            return SingleLineTextInput.normalized(combined)
        }
    }

    func makeUIView(context: Context) -> Marker {
        let view = Marker()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Marker, context: Context) { view.scheduleAttach() }

    static func dismantleUIView(_ view: Marker, coordinator: ()) { view.detach() }
}
