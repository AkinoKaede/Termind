import Foundation

public enum SFTPNotificationContent {
    public static func make(succeeded: Int, failed: Int) -> (title: String, body: String) {
        (
            String(localized: AppStrings.SFTP.transfers),
            String(localized: AppStrings.Notifications.transfersCompleted(succeeded: succeeded, failed: failed))
        )
    }
}
