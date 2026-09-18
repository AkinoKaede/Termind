import SwiftUI
import TermindApplication
import TermindDomain
import UIKit

/// Content-sized segments keep the longer follow-global label readable on phones.
struct MobileHostIntegrationPicker: UIViewRepresentable {
    private static let modes: [HostShellIntegrationMode] = [.enabled, .followGlobalSettings, .disabled]
    @Binding var mode: HostShellIntegrationMode
    @Environment(\.locale) private var locale

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: ["", "", ""])
        control.apportionsSegmentWidthsByContent = true
        control.addTarget(context.coordinator, action: #selector(Coordinator.select(_:)), for: .valueChanged)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.mode = $mode
        let labels = [
            AppLocalization.string("Enable", locale: locale),
            AppLocalization.string("Follow Global Settings", locale: locale),
            AppLocalization.string("Disable", locale: locale),
        ]
        for (index, label) in labels.enumerated() { control.setTitle(label, forSegmentAt: index) }
        control.accessibilityLabel = AppLocalization.string("Shell Integration", locale: locale)
        control.selectedSegmentIndex = Self.modes.firstIndex(of: mode) ?? 1
        control.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: uiView.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(mode: $mode) }

    final class Coordinator: NSObject {
        var mode: Binding<HostShellIntegrationMode>

        init(mode: Binding<HostShellIntegrationMode>) { self.mode = mode }

        @objc func select(_ control: UISegmentedControl) {
            guard MobileHostIntegrationPicker.modes.indices.contains(control.selectedSegmentIndex) else { return }
            mode.wrappedValue = MobileHostIntegrationPicker.modes[control.selectedSegmentIndex]
        }
    }
}
