import AgentKit
import Foundation

@MainActor
public protocol SkillLibraryPersisting: AnyObject {
    func load() throws -> [AgentSkill]
    func save(_ skills: [AgentSkill]) throws
}
