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
}
