import SwiftUI
import TermindDomain

/// Apps inject state/actions; Presentation never owns or starts a sync engine.
public struct CloudSyncCategoryPresentation: Identifiable {
    public let id: String
    public let actionID: String
    public let title: LocalizedStringResource
    public let isSelected: Bool
    public let status: VaultSyncStatus
    public let retry: () -> Void
    public let merge: () -> Void
    public init(
        id: String, actionID: String? = nil, title: LocalizedStringResource, isSelected: Bool = true,
        status: VaultSyncStatus?, retry: @escaping () -> Void, merge: @escaping () -> Void
    ) {
        self.id = id
        self.actionID = actionID ?? id
        self.title = title
        self.isSelected = isSelected
        self.status = status ?? .checkingAccount
        self.retry = retry
        self.merge = merge
    }
}

/// One account-level status; detailed diagnostics belong in application Logging.
/// Category switches select content; they are deliberately separate from status rows.
public struct CloudSyncSummaryView: View {
    public let categories: [CloudSyncCategoryPresentation]
    public let isActive: Bool
    public init(categories: [CloudSyncCategoryPresentation], isActive: Bool) {
        self.categories = categories
        self.isActive = isActive
    }
    private var selected: [CloudSyncCategoryPresentation] { categories.filter(\.isSelected) }
    private var retryable: [CloudSyncCategoryPresentation] {
        selected.filter {
            if case .failed = $0.status { return true }
            if case .partiallyBlocked = $0.status { return true }
            return false
        }
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VaultSyncStatusLabel(status: CloudSyncStatusSummary.make(selected.map(\.status), isActive: isActive))
            if isActive {
                if selected.contains(where: { $0.status == .accountChangeConfirmationRequired }) {
                    Button(AppStrings.Settings.mergeWithThisICloudAccount.swiftUIKey) {
                        var handled = Set<String>()
                        for category in selected where category.status == .accountChangeConfirmationRequired {
                            if handled.insert(category.actionID).inserted { category.merge() }
                        }
                    }
                }
                if !retryable.isEmpty {
                    Button(AppStrings.Common.retry.swiftUIKey) {
                        var handled = Set<String>()
                        for category in retryable where handled.insert(category.actionID).inserted { category.retry() }
                    }
                }
            }
        }
    }
}
