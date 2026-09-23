import SwiftUI
import TermindApplication

public struct LoggingSettingsSection: View {
    @Binding private var saving: Bool
    @Binding private var level: String

    public init(saving: Binding<Bool>, level: Binding<String>) {
        _saving = saving
        _level = level
    }

    public var body: some View {
        Section {
            Toggle(TermindCopy.Common.save.swiftUIKey, isOn: $saving)
            Picker(TermindCopy.Settings.level.swiftUIKey, selection: $level) {
                ForEach(ApplicationLogLevel.allCases) { level in
                    Text(verbatim: level.localizedName).tag(level.rawValue)
                }
            }
        } header: {
            Text(TermindCopy.Settings.logging)
        } footer: {
            Text(TermindCopy.Settings.logSharingWarning)
        }
    }
}
