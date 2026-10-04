import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct SnippetCardDataTests {
    @Test func legacyTimestampFallbackIsStableUntilARealEditExists() throws {
        let suiteName = "termind.snippet-timestamp-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fallback = SnippetTimestamp.fallback(in: defaults)
        #expect(SnippetTimestamp.fallback(in: defaults) == fallback)
        #expect(
            SnippetTimestamp.resolve(modifiedAt: VaultVersion.baselineDate, fallback: fallback)
                == fallback)

        let editedAt = fallback.addingTimeInterval(60)
        #expect(SnippetTimestamp.resolve(modifiedAt: editedAt, fallback: fallback) == editedAt)
    }

    @Test func legacyPreferenceIsPreservedAndMissingDatesUseTheSameFallback() throws {
        let defaults = try #require(UserDefaults(suiteName: "snippet-legacy-\(UUID().uuidString)"))
        let key = "mobile.snippets.baselineModifiedAtFallback.v1"
        defer { defaults.removeObject(forKey: key) }
        let saved = Date(timeIntervalSince1970: 1_700_000_000)
        defaults.set(saved, forKey: key)

        let fallback = SnippetTimestamp.fallback(in: defaults)
        #expect(fallback == saved)
        #expect(SnippetTimestamp.resolve(modifiedAt: nil, fallback: fallback) == saved)
    }

    @Test func targetsExcludeMissingAndNonSSHHostsAndRespondToProtocolChanges() {
        let ssh = Host(name: "SSH", host: "ssh.invalid")
        var telnet = Host(name: "Telnet", host: "telnet.invalid", sshEnabled: false, telnetEnabled: true)
        let unrelated = Host(name: "Other", host: "other.invalid")
        let library = HostLibraryModel(hosts: [ssh, telnet, unrelated])
        let snippets = SnippetLibraryModel(library: library)
        var snippet = Snippet(title: "Status", body: "uptime")
        #expect(snippets.validTargetIDs(for: snippet).isEmpty)

        snippet.targetHostIDs = [ssh.id, telnet.id, UUID()]
        #expect(snippets.validTargetIDs(for: snippet) == [ssh.id])

        telnet.sshEnabled = true
        library.upsert(telnet)
        #expect(Set(snippets.validTargetIDs(for: snippet)) == [ssh.id, telnet.id])
        library.projectHostDeletion(ssh.id)
        #expect(snippets.validTargetIDs(for: snippet) == [telnet.id])
    }
}
