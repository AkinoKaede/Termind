import SwiftUI
import TermindApplication
import TermindDomain

public struct SFTPSettingsFields: View {
    let model: SFTPSettingsModel
    let access: MultiConnectionSettingsAccess

    public init(
        model: SFTPSettingsModel,
        access: MultiConnectionSettingsAccess = .init(isAllowed: true, requestAccess: {})
    ) {
        self.model = model
        self.access = access
    }
    public var body: some View {
        Picker(AppStrings.SFTP.concurrentStrategy, selection: access.strategy(for: model)) {
            Text(AppStrings.SFTP.smart)
                .tag(SFTPConcurrencyStrategy.smart)
            Text(AppStrings.SFTP.channelsOnly).tag(SFTPConcurrencyStrategy.channelsOnly)
            Text(AppStrings.SFTP.connectionsPreferred)
                .tag(SFTPConcurrencyStrategy.connectionsPreferred)
        }
        if access.strategy(for: model).wrappedValue == .smart {
            Text(AppStrings.SFTP.smartStrategyExplanation)
                .font(.caption).foregroundStyle(.secondary)
        }
        Stepper(value: binding(\.globalLimit), in: SFTPPreferences.globalLimitRange) {
            label(AppStrings.SFTP.concurrentTransfers, value: model.preferences.globalLimit)
        }
        Stepper(value: binding(\.perHostLimit), in: model.preferences.availablePerHostRange) {
            label(AppStrings.SFTP.perHostTransfers, value: model.preferences.perHostLimit)
        }
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

}
