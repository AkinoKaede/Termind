import SwiftUI
import TermindApplication
import TermindDomain

public struct NotificationSettingsFields: View {
    private let model: NotificationSettingsModel
    private let service: any NotificationSending
    private let openSettings: () -> Void
    @State private var authorization = NotificationAuthorization.notDetermined
    @Environment(\.scenePhase) private var scenePhase

    public init(model: NotificationSettingsModel, service: any NotificationSending, openSettings: @escaping () -> Void)
    {
        self.model = model
        self.service = service
        self.openSettings = openSettings
    }

    public var body: some View {
        Section {
            Toggle(AppStrings.Notifications.enabled, isOn: binding(\.isEnabled))
            if model.preferences.usesSystemNotifications {
                if authorization == .denied {
                    Text(AppStrings.CommandNotifications.denied).foregroundStyle(.secondary)
                    Button(AppStrings.CommandNotifications.openSettings, action: openSettings)
                } else if authorization == .notDetermined {
                    Button(AppStrings.Notifications.allow) {
                        Task { authorization = await service.authorization(request: true) }
                    }
                }
            }
            if let error = model.storageError { Text(error).foregroundStyle(.red) }
        }
        Section(AppStrings.Navigation.assistant) {
            modePicker(\.assistantMode)
        }
        .disabled(!model.preferences.isEnabled)
        Section {
            modePicker(\.terminalMode)
            Group {
                Picker(AppStrings.Notifications.delivery, selection: binding(\.terminalDelivery)) {
                    Text(AppStrings.Notifications.system).tag(
                        NotificationPreferences.TerminalDelivery.systemNotifications)
                    Text(AppStrings.Notifications.bell).tag(NotificationPreferences.TerminalDelivery.bell)
                }
                .pickerStyle(.menu)
                Stepper(value: binding(\.terminalMinimumSeconds), in: 0...Int.max, step: 1) {
                    #if os(macOS)
                        HStack {
                            Text(AppStrings.CommandNotifications.seconds)
                            Spacer()
                            Text(model.preferences.terminalMinimumSeconds, format: .number).monospacedDigit()
                        }
                    #else
                        LabeledContent(AppStrings.CommandNotifications.seconds.swiftUIKey) {
                            Text(model.preferences.terminalMinimumSeconds, format: .number).monospacedDigit()
                        }
                    #endif
                }
            }
            .disabled(model.preferences.terminalMode == .never)
        } header: {
            Text(AppStrings.Settings.terminal)
        } footer: {
            VStack(alignment: .leading) {
                Text(AppStrings.CommandNotifications.explanation).fixedSize(horizontal: false, vertical: true)
                #if os(iOS)
                    Text(AppStrings.CommandNotifications.mobileExplanation).fixedSize(horizontal: false, vertical: true)
                #endif
            }
        }
        .disabled(!model.preferences.isEnabled)
        Section {
            modePicker(\.sftpMode)
        } header: {
            Text(AppStrings.SFTP.sftp)
        } footer: {
            Text(AppStrings.Notifications.sftpExplanation)
        }
        .disabled(!model.preferences.isEnabled)
        .task { authorization = await service.authorization(request: false) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { authorization = await service.authorization(request: false) } }
        }
    }

    private func modePicker(_ path: WritableKeyPath<NotificationPreferences, NotificationPreferences.Mode>) -> some View
    {
        Picker(AppStrings.CommandNotifications.when, selection: binding(path)) {
            Text(AppStrings.CommandNotifications.never).tag(NotificationPreferences.Mode.never)
            Text(AppStrings.Notifications.unfocused).tag(NotificationPreferences.Mode.unfocused)
            Text(AppStrings.CommandNotifications.always).tag(NotificationPreferences.Mode.always)
        }
        .pickerStyle(.menu)
    }

    private func binding<Value>(_ path: WritableKeyPath<NotificationPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.preferences[keyPath: path] },
            set: { value in
                let previouslyUsedSystem = model.preferences.usesSystemNotifications
                guard model.set(value, for: path) else { return }
                if !previouslyUsedSystem, model.preferences.usesSystemNotifications {
                    Task { authorization = await service.authorization(request: true) }
                }
            })
    }
}
