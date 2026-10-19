import Foundation
import TermindApplication
import TermindRemoteInfrastructure
import Testing

@Suite @MainActor
struct SSHImportUsernameTests {
    @Test func importRequiresAnExplicitUsernameWhenTheConfigurationOmitsIt() async throws {
        let library = HostLibraryModel()
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appending(path: "config")
        let config = "Host remote\n    HostName example.invalid\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        let model = SSHImportModel(library: library, reader: SSHImportReader(username: "", home: root))
        await model.scan(root, knownHostsOnly: false)
        #expect(model.error == nil)
        #expect(model.selectedItems(.hosts).count == 1)
        #expect(model.selectedItems(.identities).count == 1)
        #expect(!model.canImport)
        await model.commit()
        #expect(!model.completed)
        #expect(library.hosts.isEmpty && library.identities.isEmpty)

        // Rescan the corrected source so both Host and Identity previews are rebuilt together.
        try (config + "    User deploy\n").write(to: configURL, atomically: true, encoding: .utf8)
        await model.scan(root, knownHostsOnly: false)
        #expect(model.error == nil)
        #expect(model.selectedItems(.identities).map { $0.identity?.username } == ["deploy"])
        #expect(model.canImport)
        await model.commit()
        #expect(model.completed)
        #expect(model.error == nil)
        #expect(library.hosts.count == 1 && library.identities.count == 1)
        let host = try #require(library.hosts.first)
        #expect(library.identity(for: host)?.username == "deploy")
    }

}
