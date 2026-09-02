import Foundation

@MainActor
protocol SkillLibraryPersisting: AnyObject {
    func load() throws -> [AgentSkill]
    func save(_ skills: [AgentSkill]) throws
}
