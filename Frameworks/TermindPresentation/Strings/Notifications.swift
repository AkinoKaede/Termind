import AgentKit
import Foundation
import TermindApplication

extension AppStrings {
    public nonisolated enum Notifications {
        public static var title: LocalizedStringResource { "Notifications" }
        public static var enabled: LocalizedStringResource { "Enable Notifications" }
        public static var allow: LocalizedStringResource { "Allow Notifications" }
        public static var delivery: LocalizedStringResource { "Notification Type" }
        public static var system: LocalizedStringResource { "System Notifications" }
        public static var bell: LocalizedStringResource { "Bell" }
        public static var unfocused: LocalizedStringResource { "Unfocused" }
        public static var markRead: LocalizedStringResource { "Mark as Read" }
        public static var markUnread: LocalizedStringResource { "Mark as Unread" }
        public static func transfersCompleted(succeeded: Int, failed: Int) -> LocalizedStringResource {
            if failed == 0 {
                return succeeded == 1 ? "The transfer is complete." : "All \(succeeded) transfers are complete."
            }
            if succeeded == 0 {
                return failed == 1 ? "The transfer failed." : "All \(failed) transfers failed."
            }
            return "Transfers finished: \(succeeded) completed, \(failed) failed."
        }
        public static func unread(_ count: Int) -> LocalizedStringResource { "Unread notifications: \(count)" }

        public static func body(_ kind: AssistantNotificationKind) -> LocalizedStringResource {
            switch kind {
            case .completed: "The task is complete."
            case .failed: "The task failed. Open the conversation for details."
            case .questions: "Please provide some information to continue."
            case .secret: "Please enter your credentials to continue."
            case .approval: "An action needs your approval."
            case .authentication: "Please complete SSH authentication to continue."
            case .passphrase: "Please enter your SSH key passphrase."
            case .hostKey: "Please confirm this host's key to continue."
            }
        }
    }
}

public enum AssistantNotificationContent {
    public static func make(
        _ conversation: ConversationModel, kind: AssistantNotificationKind, runID: UUID? = nil
    ) -> (title: String, body: String) {
        let title = conversation.derivedTitle
        let sanitized = title.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : String($0)
        }.joined()
        var body = String(localized: AppStrings.Notifications.body(kind))
        if kind == .completed, let runID,
            let reply = conversation.transcript.last(where: {
                $0.role == .assistant && $0.toolCalls.isEmpty && conversation.messageRunIDs[$0.id] == runID
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        {
            body = AgentSensitiveDataRedactor.visibleText(
                reply.text.trimmingCharacters(in: .whitespacesAndNewlines), maximumCharacters: 2_000)
        } else if kind == .failed, let runID,
            let reason = conversation.runSummaries[runID]?.failure?.trimmingCharacters(in: .whitespacesAndNewlines),
            !reason.isEmpty
        {
            body = AgentSensitiveDataRedactor.visibleText(reason, maximumCharacters: 500)
        }
        return (String(sanitized.prefix(160)), body)
    }
}
