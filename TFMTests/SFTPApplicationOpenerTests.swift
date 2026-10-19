import AppKit
import Testing

@testable import Termind

@MainActor
struct SFTPApplicationOpenerTests {
    @Test func defaultApplicationComesFirstAndAliasesAreDeduplicated() {
        let preferred = URL(filePath: "/Applications/Zed.app")
        let alpha = URL(filePath: "/Applications/Alpha.app")
        let beta = URL(filePath: "/Applications/Beta.app")
        let result = SFTPApplicationOpener.applications(
            urls: [beta, alpha, preferred, URL(filePath: "/Applications/./Zed.app")],
            defaultURL: preferred, name: { $0.deletingPathExtension().lastPathComponent }, icon: { _ in nil })
        #expect(result.map(\.url) == [preferred, alpha, beta])
        #expect(result.map(\.isDefault) == [true, false, false])
    }

    @Test func defaultApplicationIsIncludedEvenWhenMissingFromRecommendations() {
        let preferred = URL(filePath: "/Applications/Editor.app")
        let result = SFTPApplicationOpener.applications(
            urls: [], defaultURL: preferred, name: { $0.lastPathComponent }, icon: { _ in nil })
        #expect(result.count == 1)
        #expect(result.first?.url == preferred)
    }

    @Test func appStoreSearchUsesTheFilenameExtension() throws {
        let url = try #require(SFTPApplicationOpener.appStoreSearchURL(for: "Quarterly Report.pages"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "macappstore")
        #expect(components.queryItems?.first(where: { $0.name == "term" })?.value == "pages")
        #expect(SFTPApplicationOpener.appStoreSearchURL(for: "README") == nil)
    }

    // Launch Services may show a system alert even though this open request is expected to fail.
    @Test(.requiresVisibleWindow) func missingApplicationPropagatesLaunchFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "report.txt")
        try Data("test".utf8).write(to: file)
        await #expect(throws: (any Error).self) {
            try await SFTPApplicationOpener.open(file, with: directory.appending(path: "Missing.app"))
        }
    }

    @Test func unknownTypeAndExtensionlessFilesHaveNoFabricatedApplications() {
        #expect(SFTPApplicationOpener.applications(for: "README").isEmpty)
        #expect(SFTPApplicationOpener.applications(for: ".gitignore").isEmpty)
        #expect(
            SFTPApplicationOpener.applications(urls: [], defaultURL: nil, name: { $0.path }, icon: { _ in nil }).isEmpty
        )
    }
}
