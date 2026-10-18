import SwiftUI

/// Shared failure content; each platform supplies its native actions and shortcuts.
public struct ConnectionJourneyFailureCard<Actions: View>: View {
    let message: String
    let danger: Color
    let isCompact: Bool
    let actions: Actions

    public init(
        message: String, danger: Color = .red, isCompact: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) {
        self.message = message
        self.danger = danger
        self.isCompact = isCompact
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(AppStrings.Connections.connectionFailed.swiftUIKey, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(danger)
            Text(message)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            actions
        }
        .padding(isCompact ? 14 : 18)
        .frame(maxWidth: isCompact ? 380 : nil)
        .background(danger.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(danger.opacity(0.3))
        }
    }
}
