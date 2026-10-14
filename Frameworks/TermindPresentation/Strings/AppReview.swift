import Foundation

extension AppStrings {
    public nonisolated enum AppReview {
        public static var title: LocalizedStringResource { "Enjoying Termind?" }
        public static var message: LocalizedStringResource { "Share your experience on the App Store." }
        public static var accept: LocalizedStringResource { "Yes" }
        public static var decline: LocalizedStringResource { "No, thanks" }
        public static var previewTitle: LocalizedStringResource { "Review Invitation" }
        public static var showInvitation: LocalizedStringResource { "Show Review Invitation" }
        public static var previewExplanation: LocalizedStringResource {
            "Show a test invitation on the hosts list. It does not open the App Store or change your review preference."
        }
    }
}
