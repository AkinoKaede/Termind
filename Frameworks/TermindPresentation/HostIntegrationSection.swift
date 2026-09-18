import SwiftUI
import TermindDomain

public struct HostIntegrationSection<Selection: View>: View {
    private let selection: Selection

    public init(@ViewBuilder selection: () -> Selection) { self.selection = selection() }

    public var body: some View {
        Section("Integration") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Shell Integration")
                selection.frame(maxWidth: .infinity)
            }
        }
    }
}

public struct HostShellIntegrationPicker: View {
    @Binding private var mode: HostShellIntegrationMode

    public init(mode: Binding<HostShellIntegrationMode>) { _mode = mode }

    public var body: some View {
        Picker("Shell Integration", selection: $mode) {
            Text("Enable").tag(HostShellIntegrationMode.enabled)
            Text("Follow Global Settings").tag(HostShellIntegrationMode.followGlobalSettings)
            Text("Disable").tag(HostShellIntegrationMode.disabled)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }
}
