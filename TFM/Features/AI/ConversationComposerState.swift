import Foundation

/// Draft and attachment state owned by the composer rather than the runtime or
/// transcript. A conversation exposes compatibility accessors while views move
/// toward observing this focused state directly.
@Observable
final class ConversationComposerState {
    var attachments: [ContextChip] = []
    var pendingAttachments: [PendingContextAttachment] = []
    var attachmentImportError: String?
    var draft = ""
    /// A skill `/skill` named for the next message, by name.
    ///
    /// Beside the attachments rather than on the conversation, and consumed the
    /// same way: it belongs to the message being written, and the chip going
    /// away is how the user sees it was sent. Unlike plan mode — a posture that
    /// outlives the turn — this is one instruction for one message.
    var armedSkillName: String?
}
