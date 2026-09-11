import Foundation
import TermindApplication
import TermindDomain

/// One injected command surface for durable Assistant conversation mutations.
/// Windows keep navigation state; AppModel owns persistence and cross-window
/// effects behind this cohesive service instead of installing seven callbacks.
@MainActor
final class AssistantConversationCommands {
    let delete: (ConversationModel.ID) -> Void
    let togglePin: (ConversationModel.ID) -> Void
    let move: (ConversationModel.ID, Bool, ConversationModel.ID?) -> Void
    let rename: (ConversationModel.ID, String) -> Void
    let archive: (ConversationModel.ID, Bool) -> Void
    let fork: (ConversationModel.ID, UUID, Bool) -> Void
    let edit: (ConversationModel.ID, UUID, String, SessionContext, Bool) -> Void

    init(
        delete: @escaping (ConversationModel.ID) -> Void,
        togglePin: @escaping (ConversationModel.ID) -> Void,
        move: @escaping (ConversationModel.ID, Bool, ConversationModel.ID?) -> Void,
        rename: @escaping (ConversationModel.ID, String) -> Void,
        archive: @escaping (ConversationModel.ID, Bool) -> Void,
        fork: @escaping (ConversationModel.ID, UUID, Bool) -> Void,
        edit: @escaping (ConversationModel.ID, UUID, String, SessionContext, Bool) -> Void
    ) {
        self.delete = delete
        self.togglePin = togglePin
        self.move = move
        self.rename = rename
        self.archive = archive
        self.fork = fork
        self.edit = edit
    }
}
