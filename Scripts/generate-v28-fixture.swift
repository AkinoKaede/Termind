import Foundation
import SwiftData
import TermindDomain
import TermindPersistence

// V28.store source: 0dc173d4b1d190071d35bc66f80ebb767d8b950c (the parent of b0d35d24).
// Build that checkout's TermindPersistence scheme for macOS with -onlyUsePackageVersionsFromResolvedFile.
// Compile this generator with -parse-as-library, using that build's -F/-I products, GRDBSQLite module path,
// TermindPersistence/TermindDomain/TermindApplication frameworks, and AgentKit.o/Logging.o.
// Pass a new temporary store path, then use SQLite's backup API to produce the standalone fixture after exit.
// Never regenerate against current models. All data is synthetic; no password or private key is stored.
// Expected schema checksum: hh/HY7td7OFShC/UhxiuwAlJuf8IZOWsZm7U7VqLaSs=
@main
struct GenerateV28Fixture {
    @MainActor
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let schema = Schema(versionedSchema: TermindSchemaV28.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)])
        let context = container.mainContext
        let groupID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let hostID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let identityID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let keyID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let historyID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let installationID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let knownHostID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let snippetID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let host = TermindSchemaV28HostModels.PersistentHost(
            Host(
                id: hostID, name: "V28 fixture host", host: "legacy.example.invalid", port: 2222,
                identityID: identityID, charset: .gb18030, groupID: groupID,
                tags: ["legacy", "ssh"], colorTag: .teal, sortIndex: 2.5,
                shellIntegrationMode: .disabled, startupSnippetID: snippetID,
                environmentVariables: [
                    HostEnvironmentVariable(variable: "LANG", value: "zh_CN.GB18030"),
                    HostEnvironmentVariable(variable: "TERM", value: "xterm-256color"),
                ], portForwardingMaxConnections: 3))
        host.sftpSessionInitialPath = "/srv/legacy"
        host.lastUsedAt = Date(timeIntervalSince1970: 100)
        context.insert(host)
        context.insert(PersistentHostGroup(HostGroup(id: groupID, name: "V28 fixture group")))
        context.insert(
            PersistentIdentity(
                Identity(
                    id: identityID, name: "V28 fixture identity", username: "deploy",
                    credentialRef: "termind.fixture.password", passwordStorage: .thisDevice,
                    keyID: keyID, notes: "Synthetic fixture", colorTag: .purple)))
        context.insert(PersistentSSHKey(SSHKeyRef(id: keyID, label: "V28 fixture key")))
        let knownHost = TermindSchemaV29KnownHostModels.PersistentKnownHost(
            KnownHostEntry(
                id: knownHostID, hostname: "legacy.example.invalid", port: 2222,
                fingerprint: "SHA256:fixture", addedAt: Date(timeIntervalSince1970: 50)))
        knownHost.isMismatched = true
        context.insert(knownHost)
        context.insert(
            PersistentSnippet(
                Snippet(id: snippetID, title: "V28 fixture snippet", body: "pwd", targetHostIDs: [hostID])))
        context.insert(
            PersistentConnectionHistoryEntry(
                ConnectionHistoryEntry(
                    id: historyID, hostID: hostID, kind: .ssh, connectedAt: Date(timeIntervalSince1970: 90))))
        let state = PersistentVaultSyncState()
        state.installationID = installationID
        state.bootstrapCompleted = true
        context.insert(state)
        try context.save()
    }
}
