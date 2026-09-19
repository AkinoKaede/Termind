import SwiftUI
import TermindDomain

public struct HostIntegrationSection: View {
    @Binding private var mode: HostShellIntegrationMode

    public init(mode: Binding<HostShellIntegrationMode>) { _mode = mode }

    public var body: some View {
        Section("Integration") {
            Picker("Shell Integration", selection: $mode) {
                Text("Default").tag(HostShellIntegrationMode.followGlobalSettings)
                Text("Enable").tag(HostShellIntegrationMode.enabled)
                Text("Disable").tag(HostShellIntegrationMode.disabled)
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)
        }
    }
}
