import AgentKit
import Foundation

/// Reading a skill off disk, kept out of the view so the parsing decisions are
/// testable without a panel.
public enum SkillImporter {
    public struct Outcome {
        public var document: AgentSkillDocument
        public var origin: String
        public var warnings: [String] = []
    }

    public static func read(_ url: URL) throws -> Outcome {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = values.isDirectory == true
        let file = isDirectory ? url.appending(path: "SKILL.md") : url
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw AgentSkillImportError.noSkillFile
        }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: AgentSkill.maximumBodyBytes + 1) ?? Data()
        guard data.count <= AgentSkill.maximumBodyBytes else {
            throw AgentSkillImportError.tooLarge
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentSkillImportError.notReadable
        }

        // The folder name is the skill name for anything written against the
        // standard, where the directory *is* the identifier.
        let source = isDirectory ? url : url.deletingPathExtension()
        let document = try AgentSkillDocument.parse(
            text, fallbackName: source.lastPathComponent
        )
        return Outcome(
            document: document, origin: file.lastPathComponent,
            warnings: isDirectory ? bundledFileWarnings(in: url) : []
        )
    }

    /// Says what was left behind. A skill written for pi or Claude Code may ship
    /// `scripts/` and `references/`; Termind imports the Markdown only, and
    /// silently dropping the rest would leave the model following steps that
    /// reference files nobody has.
    private static func bundledFileWarnings(in directory: URL) -> [String] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        let extras = (contents ?? [])
            .filter { $0.lastPathComponent != "SKILL.md" }
            .map(\.lastPathComponent)
            .sorted()
        guard !extras.isEmpty else { return [] }
        let names = extras.joined(separator: ", ")
        return [String(localized: "Only SKILL.md was imported. These were not: \(names).")]
    }
}
