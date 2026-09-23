import SwiftUI
import TermindApplication
import TermindDomain

public struct SFTPSettingsFields: View {
    let model: SFTPSettingsModel

    public init(model: SFTPSettingsModel) { self.model = model }

    public var body: some View {
        Picker("Concurrent Strategy", selection: strategyBinding) {
            Text("Smart").tag(SFTPConcurrencyStrategy.smart)
            Text("Channels Only").tag(SFTPConcurrencyStrategy.channelsOnly)
            Text("Connections Preferred").tag(SFTPConcurrencyStrategy.connectionsPreferred)
        }
        if model.preferences.strategy == .smart {
            Text(
                "Smart uses channels for files up to 64 MB and prefers additional connections for larger files. Transfers with an unknown size use channels."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        Stepper(value: binding(\.globalLimit), in: SFTPPreferences.globalLimitRange) {
            label("Concurrent Transfers", value: model.preferences.globalLimit)
        }
        Stepper(value: binding(\.perHostLimit), in: model.preferences.availablePerHostRange) {
            label("Per-Host Transfers", value: model.preferences.perHostLimit)
        }
        Text(
            "Changes apply to queued transfers. Active transfers continue unchanged. If additional connections cannot open without authentication prompts, transfers use parallel channels on the existing connection."
        )
        .font(.caption).foregroundStyle(.secondary)
        if let error = model.storageError { Text(error).foregroundStyle(.red) }
    }

    @ViewBuilder
    private func label(_ title: LocalizedStringResource, value: Int) -> some View {
        #if os(macOS)
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .number).monospacedDigit()
            }
        #else
            LabeledContent(title.swiftUIKey) {
                Text(value, format: .number).monospacedDigit()
            }
        #endif
    }

    private func binding(_ keyPath: WritableKeyPath<SFTPPreferences, Int>) -> Binding<Int> {
        Binding(get: { model.preferences[keyPath: keyPath] }, set: { model.set($0, for: keyPath) })
    }

    private var strategyBinding: Binding<SFTPConcurrencyStrategy> {
        Binding(get: { model.preferences.strategy }, set: { model.setStrategy($0) })
    }
}
