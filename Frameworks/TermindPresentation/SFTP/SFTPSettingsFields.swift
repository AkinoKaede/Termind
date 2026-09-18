import SwiftUI
import TermindApplication
import TermindDomain

public struct SFTPSettingsFields: View {
    let model: SFTPSettingsModel

    public init(model: SFTPSettingsModel) { self.model = model }

    public var body: some View {
        Stepper(value: binding(\.globalLimit), in: SFTPPreferences.globalLimitRange) {
            label("Concurrent Transfers", value: model.preferences.globalLimit)
        }
        Stepper(value: binding(\.perHostLimit), in: model.preferences.availablePerHostRange) {
            label("Per-Host Transfers", value: model.preferences.perHostLimit)
        }
        Text(
            "Changes apply to queued transfers. Active transfers continue unchanged. If additional connections cannot open without authentication prompts, the session transfers files one at a time."
        )
        .font(.caption).foregroundStyle(.secondary)
        if let error = model.storageError { Text(error).foregroundStyle(.red) }
    }

    @ViewBuilder
    private func label(_ title: LocalizedStringKey, value: Int) -> some View {
        #if os(macOS)
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .number).monospacedDigit()
            }
        #else
            LabeledContent(title) {
                Text(value, format: .number).monospacedDigit()
            }
        #endif
    }

    private func binding(_ keyPath: WritableKeyPath<SFTPPreferences, Int>) -> Binding<Int> {
        Binding(get: { model.preferences[keyPath: keyPath] }, set: { model.set($0, for: keyPath) })
    }
}
