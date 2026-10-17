import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct TerminalTransportTests {
    @Test func defaultsKeepSSHAndDisablingTheDefaultDoesNotSelectAnotherEnabledTransport() {
        var host = Host(name: "Server", host: "example.invalid")
        #expect(host.preferredTerminalProtocol == .ssh)
        host.terminalTransports.moshEnabled = true
        host.terminalTransports.eternalTerminalEnabled = true
        host.telnetEnabled = true
        #expect(host.supportedTerminalProtocols == [.ssh, .mosh, .eternalTerminal, .telnet])
        host.terminalTransports.defaultTransport = .mosh
        #expect(host.preferredTerminalProtocol == .mosh)
        host.terminalTransports.moshEnabled = false
        host.terminalTransports.normalizeDefault(isTailscaleManaged: false)
        #expect(host.terminalTransports.defaultTransport == .ssh)
        host.sshEnabled = false
        #expect(host.supportedTerminalProtocols == [.telnet])
        #expect(host.preferredTerminalProtocol == .telnet)
        #expect(host.terminalTransports.eternalTerminalEnabled)
    }

    @Test func rangeValidationCannotInjectBootstrapArguments() {
        for valid in ["", "1", "65535", "60001-60999", "1-65535"] {
            #expect(HostTerminalTransports.isValidMoshPortRange(valid))
        }
        for invalid in ["0", "65536", "-1", "2-1", "60001-", "1-2-3", "1;id", " 22", "22\n", "６０００１"] {
            #expect(!HostTerminalTransports.isValidMoshPortRange(invalid))
        }
        var options = HostTerminalTransports()
        options.eternalTerminalEnabled = true
        options.eternalTerminalPort = 65_536
        #expect(!options.isValid)
        options.eternalTerminalPort = 2022
        #expect(options.isValid)
    }

    @Test func transportNamesAndSymbolsAreDistinctAndOrderedBeforeTelnet() {
        #expect(HostTerminalProtocol.allCases == [.ssh, .mosh, .eternalTerminal, .telnet])
        #expect(HostTerminalProtocol.mosh.displayName == "Mosh")
        #expect(HostTerminalProtocol.eternalTerminal.displayName == "Eternal Terminal")
        #expect(Set(HostTerminalProtocol.allCases.map(\.symbol)).count == 4)
        #expect(ConnectionHistoryEntry.Kind.mosh.symbol == HostTerminalProtocol.mosh.symbol)
        #expect(ConnectionHistoryEntry.Kind.eternalTerminal.symbol == HostTerminalProtocol.eternalTerminal.symbol)
    }

    @Test func legacyHostDecodesWithSSHAndTransportPreferencesSurviveReopening() throws {
        var host = Host(name: "Host", host: "server.invalid", iconOverrideID: "macos")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
        json.removeValue(forKey: "terminalTransports")
        let legacyHost = try JSONDecoder().decode(Host.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacyHost.terminalTransports == .init())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store")
        do {
            let schema = Schema(versionedSchema: TermindSchemaV54.self)
            let legacy = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none))
            legacy.mainContext.insert(TermindSchemaV54HostModels.PersistentHost(host))
            try legacy.mainContext.save()
        }
        do {
            let container = try TermindPersistence.makeContainer(url: url)
            let store = HostPersistence(context: container.mainContext)
            #expect(try store.load().hosts == [host])
            host.terminalTransports.moshEnabled = true
            host.terminalTransports.eternalTerminalEnabled = true
            host.terminalTransports.defaultTransport = .eternalTerminal
            host.terminalTransports.moshUDPPortRange = "60001-60999"
            host.terminalTransports.eternalTerminalPort = 2222
            _ = try store.save(.init(hosts: [host]))
        }
        let reopened = try TermindPersistence.makeContainer(url: url)
        #expect(try HostPersistence(context: reopened.mainContext).load().hosts == [host])
    }

    @Test func wireVersionsProtectTransportChoicesFromOlderWriters() throws {
        var host = Host(name: "Host", host: "server.invalid")
        host.terminalTransports.eternalTerminalEnabled = true
        host.terminalTransports.defaultTransport = .eternalTerminal
        let payload = VaultRecordPayload.host(host)
        let envelope = VaultEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        #expect(try VaultSyncCodec.decode(VaultSyncCodec.encode(envelope)) == envelope)
        for version in [1, 2, 4, 5] {
            var old = envelope
            old.formatVersion = version
            #expect(throws: (any Error).self) { try VaultSyncCodec.encode(old) }
        }
        let template = WorkspaceTemplate(name: "ET", layout: .pane(.eternalTerminal(hostID: host.id)))
        let templatePayload = VaultRecordPayload.workspaceTemplate(template)
        let templateEnvelope = VaultEnvelope(
            key: templatePayload.key, version: .baseline(writerID: UUID()), payload: templatePayload)
        #expect(try VaultSyncCodec.decode(VaultSyncCodec.encode(templateEnvelope)) == templateEnvelope)
        var oldTemplate = templateEnvelope
        oldTemplate.formatVersion = 1
        #expect(throws: (any Error).self) { try VaultSyncCodec.encode(oldTemplate) }
    }

    @Test func tailscaleKeepsETPreferencesWithoutEnablingMosh() throws {
        var group = HostGroup(name: "Tailnet")
        group.tailscale = TailscaleGroupConfiguration(
            network: try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "test.ts.net"))
        let peer = TailscalePeer(
            stableID: "peer", name: "Server", dnsName: "server.test.ts.net", online: true,
            sshHostKeys: ["ssh-ed25519 test"])
        let library = HostLibraryModel(groups: [group])
        library.replaceTailscalePeers([peer], groupID: group.id)
        var host = try #require(library.hosts.first)
        host.terminalTransports.moshEnabled = true
        host.terminalTransports.eternalTerminalEnabled = true
        host.terminalTransports.defaultTransport = .eternalTerminal
        #expect(library.saveTailscaleHost(host))
        library.replaceTailscalePeers([peer], groupID: group.id)
        let projected = try #require(library.host(host.id))
        #expect(projected.supportedTerminalProtocols == [.ssh, .eternalTerminal])
        #expect(projected.preferredTerminalProtocol == .eternalTerminal)
        let payload = VaultRecordPayload.hostGroup(try #require(library.group(group.id)))
        let envelope = VaultEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        #expect(try VaultSyncCodec.decode(VaultSyncCodec.encode(envelope)) == envelope)
    }

    @Test func v6GroupTransportOverridesRoundTripManyPeersAndRejectInvalidKeys() throws {
        var group = HostGroup(name: "Large Tailnet")
        var configuration = TailscaleGroupConfiguration(
            network: try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "test.ts.net"))
        for index in 0..<128 {
            let id = try #require(UUID(uuidString: String(format: "aaaaaaaa-aaaa-aaaa-aaaa-%012x", index)))
            var preferences = TailscaleHostPreferences()
            preferences.username = "peer-\(index)"
            preferences.terminalTransports.eternalTerminalEnabled = index.isMultiple(of: 2)
            preferences.terminalTransports.eternalTerminalPort = 2022 + index
            preferences.terminalTransports.defaultTransport = index.isMultiple(of: 2) ? .eternalTerminal : .ssh
            configuration.hostPreferences[id] = preferences
        }
        group.tailscale = configuration
        let payload = VaultRecordPayload.hostGroup(group)
        let envelope = VaultEnvelope(
            key: payload.key, version: .baseline(writerID: UUID()), payload: payload, formatVersion: 6)
        let encoded = try VaultSyncCodec.encode(envelope)
        #expect(try VaultSyncCodec.decode(encoded) == envelope)
        let validKey = "aaaaaaaa-aaaa-aaaa-aaaa-000000000000"
        for invalidKey in [validKey.uppercased(), "not-a-uuid", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"] {
            var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            var payloadJSON = try #require(json["payload"] as? [String: Any])
            var groupJSON = try #require(payloadJSON["hostGroup"] as? [String: Any])
            var value = try #require(groupJSON["_0"] as? [String: Any])
            var transports = try #require(value["terminalTransports"] as? [String: Any])
            let preferencesJSON = try #require(transports[validKey] as? [String: Any])
            transports.removeValue(forKey: validKey)
            transports[invalidKey] = preferencesJSON
            value["terminalTransports"] = transports
            groupJSON["_0"] = value
            payloadJSON["hostGroup"] = groupJSON
            json["payload"] = payloadJSON
            let invalid = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: (any Error).self) { try VaultSyncCodec.decode(invalid) }
        }
    }

    @Test func checkpointsAreEncryptedConsumedOnceAndCannotResurrectAfterClose() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TerminalRecoveryStore(directory: directory, testingKey: Data(repeating: 7, count: 32))
        var host = Host(name: "Host", host: "server.invalid")
        host.terminalTransports.eternalTerminalEnabled = true
        let record = TerminalRecoveryRecord(id: UUID(), host: host, username: "user", transport: .eternalTerminal)
        let secret = Data("checkpoint-secret-passkey-and-counters".utf8)
        let checkpoint = TerminalTransportCheckpoint(transport: .eternalTerminal, payload: secret)
        let lease = await store.register(record.id)
        try await store.save(record, checkpoint: checkpoint, lease: lease)
        let file = try #require(
            FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ).first)
        #expect(try Data(contentsOf: file).range(of: secret) == nil)
        var changed = host
        changed.host = "another.invalid"
        await #expect(throws: (any Error).self) { try await store.consume(record.id, host: changed) }
        #expect(try await store.records().count == 1)
        #expect(try await store.consume(record.id, host: host).payload == secret)
        #expect(try await store.records().isEmpty)
        await #expect(throws: (any Error).self) { try await store.consume(record.id, host: host) }
        try await store.discard(record.id)
        await #expect(throws: (any Error).self) {
            try await store.save(record, checkpoint: checkpoint, lease: lease)
        }
        #expect(try await store.records().isEmpty)
    }

    @Test func routedResumeAuthenticatesTheJumpAndProxyButNeverTheTarget() async throws {
        let target = SSHAdditionalConnectionSnapshot.Node(
            id: UUID(), name: "Target", host: "target.invalid", port: 22,
            authentication: .init(identityID: UUID(), username: "target-user"),
            expectedHostKeys: [], proxy: nil)
        let jump = SSHAdditionalConnectionSnapshot.Node(
            id: UUID(), name: "Jump", host: "jump.invalid", port: 2222,
            authentication: .init(username: "jump-user", hasEphemeralSecret: true), expectedHostKeys: [],
            proxy: .init(kind: .socks5, hostname: "proxy.invalid", port: 1080, username: "proxy-user", identityID: nil))
        let prompts = RoutePrompts()
        let request = try await HostLibraryModel().resumableRouteRequest(
            from: .init(target: target, jumps: [jump]), authorizeHostKey: nil,
            keyboardInteractive: { challenge in
                await prompts.record(challenge)
                return ["one-shot"]
            },
            securityKeySigning: nil, hostKeyConstraints: [:])
        let challenges = await prompts.challenges
        #expect(challenges.map(\.hostname) == ["jump.invalid", "proxy.invalid"])
        #expect(challenges.map(\.username) == ["jump-user", "proxy-user"])
        #expect(challenges.allSatisfy { $0.prompts.count == 1 && !$0.prompts[0].echo })
        #expect(request.configuration.host == "target.invalid")
        #expect(request.configuration.credentials.isEmpty)
        let hop = try #require(request.configuration.jumps.first)
        guard case .password(let password) = try #require(hop.credentials.first) else {
            Issue.record("The jump should receive its one-shot password")
            return
        }
        #expect(password.matches("one-shot"))
        #expect(hop.proxy?.password?.matches("one-shot") == true)
        request.configuration.clearSecrets()
        #expect(password.isConsumed)
        #expect(hop.proxy?.password?.isConsumed == true)
    }

    @Test func cancelledRouteAuthenticationDoesNotCreateATargetConnection() async throws {
        let node = SSHAdditionalConnectionSnapshot.Node(
            id: UUID(), name: "Jump", host: "jump.invalid", port: 22,
            authentication: .init(username: "user", hasEphemeralSecret: true),
            expectedHostKeys: [], proxy: nil)
        await #expect(throws: CancellationError.self) {
            try await HostLibraryModel().resumableRouteRequest(
                from: .init(target: node, jumps: [node]), authorizeHostKey: nil,
                keyboardInteractive: { _ in throw CancellationError() }, securityKeySigning: nil,
                hostKeyConstraints: [:])
        }
    }

    @Test func explicitTmuxControlAuthenticatesTheTargetAndRetainsItsTrust() async throws {
        let key = SSHHostKeyIdentity(algorithm: .ed25519, fingerprint: "SHA256:target")
        let target = SSHAdditionalConnectionSnapshot.Node(
            id: UUID(), name: "Target", host: "target.invalid", port: 22,
            authentication: .init(username: "user", hasEphemeralSecret: true),
            expectedHostKeys: [key], proxy: nil)
        let prompts = RoutePrompts()
        let request = try await HostLibraryModel().resumableRouteRequest(
            from: .init(target: target, jumps: []), authorizeHostKey: nil,
            keyboardInteractive: { challenge in
                await prompts.record(challenge)
                return ["control-secret"]
            },
            securityKeySigning: nil, hostKeyConstraints: [:], authenticatingTarget: true)
        #expect(await prompts.challenges.map(\.hostname) == ["target.invalid"])
        #expect(request.configuration.jumps.isEmpty)
        #expect(request.configuration.expectedHostKeys == [key])
        guard case .password(let password) = try #require(request.configuration.credentials.first) else {
            Issue.record("Explicit tmux control needs target authentication")
            return
        }
        #expect(password.matches("control-secret"))
        request.configuration.clearSecrets()
        #expect(password.isConsumed)
    }

    @Test func restoredMoshControlRebuildsItsJumpRouteWithoutReadingSecrets() async throws {
        let jump = Host(name: "Jump", host: "jump.invalid")
        var target = Host(name: "Target", host: "target.invalid")
        target.jumpHostID = jump.id
        target.proxy = .init(kind: .socks5, hostname: "proxy.invalid", port: 1080)
        let library = HostLibraryModel(hosts: [jump, target])
        let snapshot = try library.resumableControlSnapshot(for: target, username: "target-user")
        #expect(snapshot.jumps.map(\.id) == [jump.id])
        #expect(snapshot.target.proxy?.hostname == "proxy.invalid")
        #expect(snapshot.target.authentication.username == "target-user")
        let prompts = RoutePrompts()
        let request = try await library.resumableRouteRequest(
            from: snapshot, authorizeHostKey: nil,
            keyboardInteractive: { challenge in
                await prompts.record(challenge)
                return [challenge.prompts.first?.echo == true ? "jump-user" : "secret"]
            },
            securityKeySigning: nil, hostKeyConstraints: [:], authenticatingTarget: true)
        defer { request.configuration.clearSecrets() }
        #expect(request.configuration.jumps.first?.username == "jump-user")
        #expect(request.configuration.username == "target-user")
        #expect(await prompts.challenges.map(\.hostname) == ["jump.invalid", "jump.invalid", "target.invalid"])
    }

    @Test func partialAuthenticatedShellEventsSurviveCheckpointEncoding() throws {
        var filter = RemoteCommandEventFilter(token: "checkpoint")
        let prefix = Data("\u{1b}]777;TermindCommand=checkpoint;echo%20".utf8)
        #expect(filter.receive(prefix).events.isEmpty)
        var restored = try JSONDecoder().decode(
            RemoteCommandEventFilter.self, from: JSONEncoder().encode(filter))
        let update = restored.receive(Data("hello\u{7}visible".utf8))
        #expect(update.events == [.commandStarted("echo hello")])
        #expect(update.visibleOutput == Data("visible".utf8))
    }

    private actor RoutePrompts {
        private(set) var challenges: [SSHKeyboardInteractiveChallenge] = []
        func record(_ challenge: SSHKeyboardInteractiveChallenge) { challenges.append(challenge) }
    }
}
