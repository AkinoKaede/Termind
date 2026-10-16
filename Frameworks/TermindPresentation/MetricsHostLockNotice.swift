import SwiftUI
import TermindApplication

public struct MetricsHostLockNotice: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "lock.fill")
            Text(AppStrings.Pro.upgradeToUnlockHost)
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityIdentifier("metrics.hostLocked")
    }
}
