import SwiftUI
import TermindApplication

public struct DiagnosisConsentView: View {
    private let controller: DiagnosisController

    public init(controller: DiagnosisController) {
        self.controller = controller
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "heart.text.clipboard")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(AppStrings.Diagnosis.invitation)
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(AppStrings.Diagnosis.explanation)
                Label {
                    Text(AppStrings.Diagnosis.privacy)
                } icon: {
                    Image(systemName: "lock.shield")
                }
                Text(AppStrings.Diagnosis.choice)
                    .foregroundStyle(.secondary)

                Link(destination: Self.privacyURL) {
                    Text(AppStrings.Pro.privacyPolicy)
                        .underline()
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                HStack {
                    declineAction
                    Spacer(minLength: 24)
                    allowButton
                }
                .controlSize(.large)
            }
            .padding(32)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let privacyURL = URL(string: "https://termind.akinokaede.com/privacy/")!

    private var allowButton: some View {
        Button(AppStrings.Common.allow.swiftUIKey) {
            controller.setEnabled(true)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("diagnosis.allow")
    }

    private var declineAction: some View {
        Button(AppStrings.Diagnosis.decline.swiftUIKey) {
            controller.setEnabled(false)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("diagnosis.decline")
    }
}

public struct DiagnosisSettingsSection: View {
    private let controller: DiagnosisController

    public init(controller: DiagnosisController) {
        self.controller = controller
    }

    public var body: some View {
        Section {
            Toggle(
                AppStrings.Diagnosis.sendDiagnosticData.swiftUIKey,
                isOn: Binding(get: { controller.isEnabled }, set: controller.setEnabled)
            )
            .toggleStyle(.switch)
        } header: {
            Text(AppStrings.Diagnosis.title)
        } footer: {
            Text(AppStrings.Diagnosis.settingsExplanation)
        }
    }
}
