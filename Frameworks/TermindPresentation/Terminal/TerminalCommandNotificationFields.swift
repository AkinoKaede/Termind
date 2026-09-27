import SwiftUI
import TermindApplication
import TermindDomain

public struct TerminalCommandNotificationFields: View {
    private let model: TerminalSettingsModel
    private let service: any CommandNotificationSending
    private let openSettings: () -> Void
    @State private var authorization = CommandNotificationAuthorization.notDetermined
    @Environment(\.scenePhase) private var scenePhase

    public init(
        model: TerminalSettingsModel, service: any CommandNotificationSending, openSettings: @escaping () -> Void
    ) {
        self.model = model
        self.service = service
        self.openSettings = openSettings
    }

    public var body: some View {
        Section {
            Picker(AppStrings.CommandNotifications.when, selection: binding(\.mode)) {
                Text(AppStrings.CommandNotifications.never).tag(CommandNotificationPreferences.Mode.never)
                Text(AppStrings.CommandNotifications.unfocused).tag(CommandNotificationPreferences.Mode.unfocused)
                Text(AppStrings.CommandNotifications.always).tag(CommandNotificationPreferences.Mode.always)
            }
            Toggle(AppStrings.CommandNotifications.system, isOn: binding(\.notify))
            Toggle(AppStrings.CommandNotifications.bell, isOn: binding(\.bell))
            LabeledContent {
                TextField(AppStrings.CommandNotifications.seconds, value: binding(\.after), format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                    #if os(iOS)
                        .keyboardType(.decimalPad)
                    #endif
            } label: {
                Text(AppStrings.CommandNotifications.seconds)
            }
            if authorization == .denied {
                Text(AppStrings.CommandNotifications.denied).foregroundStyle(.secondary)
                Button(AppStrings.CommandNotifications.openSettings, action: openSettings)
            }
        } header: {
            Text(AppStrings.CommandNotifications.title)
        } footer: {
            VStack(alignment: .leading) {
                Text(AppStrings.CommandNotifications.explanation)
                    .fixedSize(horizontal: false, vertical: true)
                #if os(iOS)
                    Text(AppStrings.CommandNotifications.mobileExplanation)
                        .fixedSize(horizontal: false, vertical: true)
                #endif
            }
        }
        .task { authorization = await service.authorization(request: false) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { authorization = await service.authorization(request: false) } }
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<CommandNotificationPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.preferences.commandNotifications[keyPath: path] },
            set: { value in
                let previous = model.preferences.commandNotifications
                var next = previous
                next[keyPath: path] = value
                guard next.after.isFinite, next.after >= 0,
                    model.set(next, for: \.commandNotifications)
                else { return }
                if next.notify, next.mode != .never, !previous.notify || previous.mode == .never {
                    Task { authorization = await service.authorization(request: true) }
                }
            })
    }
}

public struct WorkspaceCommandBadge: View {
    public init() {}
    public var body: some View {
        Circle().fill(.red).frame(width: 7, height: 7)
            .overlay { Circle().stroke(.background, lineWidth: 1) }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

public enum CommandNotificationContent {
    public static func body(_ completion: TerminalCommandCompletion) -> String {
        let duration = Duration.seconds(completion.duration).formatted(.units(allowed: [.hours, .minutes, .seconds]))
        let result: LocalizedStringResource
        switch completion.exitCode {
        case 0: result = AppStrings.CommandNotifications.succeeded(duration)
        case .some(let code): result = AppStrings.CommandNotifications.failed(code, duration)
        case nil: result = AppStrings.CommandNotifications.finished(duration)
        }
        return (completion.commandPreview ?? String(localized: AppStrings.CommandNotifications.completed))
            + "\n" + String(localized: result)
    }
}
