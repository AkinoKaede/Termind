import AppKit
import SwiftUI

extension View {
    /// Apply to a sheet's content root so the native Quit command remains available.
    func allowsApplicationTerminationWhenModal() -> some View {
        background(SheetApplicationTermination())
    }
}

private struct SheetApplicationTermination: NSViewRepresentable {
    func makeNSView(context: Context) -> SheetApplicationTerminationView {
        SheetApplicationTerminationView(frame: .zero)
    }

    func updateNSView(_ view: SheetApplicationTerminationView, context: Context) {
        view.apply()
    }

    static func dismantleNSView(_ view: SheetApplicationTerminationView, coordinator: ()) {
        view.restore()
    }
}

final class SheetApplicationTerminationView: NSView {
    private weak var configuredWindow: NSWindow?
    private var originalValue: Bool?

    isolated deinit { restore() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    func apply() {
        if configuredWindow !== window {
            restore()
            configuredWindow = window
            originalValue = window?.preventsApplicationTerminationWhenModal
        }
        // Configure as soon as the content receives its window, even before
        // AppKit attaches it to a sheet parent and validates the Quit menu item.
        window?.preventsApplicationTerminationWhenModal = false
    }

    func restore() {
        if let originalValue {
            configuredWindow?.preventsApplicationTerminationWhenModal = originalValue
        }
        configuredWindow = nil
        originalValue = nil
    }
}
