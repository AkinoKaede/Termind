// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import Testing

import struct TermindDomain.Host

@testable import TermindRemoteInfrastructure

@Suite @MainActor
struct LocalNetworkTests {
    @Test func validatesUnicastMACAndBuildsStandardPacket() throws {
        let mac = try #require(MACAddress(" 02-ab-cd-12-34-56 "))
        #expect(mac.rawValue == "02:AB:CD:12:34:56")
        let packet = Array(mac.magicPacket)
        #expect(packet.count == 102)
        #expect(Array(packet.prefix(6)) == Array(repeating: 255, count: 6))
        for offset in stride(from: 6, to: 102, by: 6) {
            #expect(Array(packet[offset..<(offset + 6)]) == [2, 171, 205, 18, 52, 86])
        }
        for text in [
            "", "00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF", "01:00:5E:01:02:03",
            "0:11:22:33:44:55", "00:11:22:33:44:5G", "001122334455", "00:11-22:33:44:55",
        ] {
            #expect(MACAddress(text) == nil)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MACAddress.self, from: Data("\"invalid\"".utf8))
        }
    }

    @Test func invalidWakePreferencesCannotReplaceASavedHost() throws {
        var original = Host(name: "Server", host: "server.invalid")
        original.wakeOnLAN = .init(macAddress: "02:11:22:33:44:55", automaticallyWake: true)
        let library = HostLibraryModel(hosts: [original])
        for preferences in [
            WakeOnLANPreferences(macAddress: "", automaticallyWake: true),
            WakeOnLANPreferences(macAddress: "02:11:22:33:44:GG", automaticallyWake: true),
            WakeOnLANPreferences(macAddress: "02:11:22:33:44:GG"),
        ] {
            var draft = original
            draft.name = "Unsaved"
            draft.wakeOnLAN = preferences
            #expect(!library.saveHost(draft))
            #expect(library.host(original.id) == original)
            #expect(library.storageError != nil)
        }
        var corrected = original
        corrected.wakeOnLAN.macAddress = "02-ab-cd-12-34-56"
        #expect(library.saveHost(corrected))
        #expect(library.host(original.id)?.wakeOnLAN.address?.rawValue == "02:AB:CD:12:34:56")
        corrected.wakeOnLAN = .init()
        #expect(library.saveHost(corrected))
        #expect(library.host(original.id)?.wakeOnLAN == .init())
        #expect(library.storageError == nil)
    }

    @Test func invalidWakePreferencesCannotCreateAHost() {
        var host = Host(name: "Server", host: "server.invalid")
        host.wakeOnLAN.automaticallyWake = true
        let library = HostLibraryModel()
        #expect(!library.saveHost(host))
        #expect(library.hosts.isEmpty)
        host.wakeOnLAN.macAddress = "02:11:22:33:44:55"
        #expect(library.saveHost(host))
        #expect(library.host(host.id)?.wakeOnLAN.automaticallyWake == true)
    }

    @Test func sendingIsFreeAndOnlyAutoUsesCooldown() throws {
        let sender = RecordingWakeSender()
        let state = WakeTestState()
        let controller = WakeOnLANController(sender: sender, now: { state.clock })
        let preferences = WakeOnLANPreferences(macAddress: "02:11:22:33:44:55", automaticallyWake: true)
        controller.automaticallyWake(preferences)
        controller.automaticallyWake(preferences)
        #expect(sender.sent.count == 1)
        try controller.wake(preferences)
        try controller.wake(preferences)
        #expect(sender.sent.count == 3)
        state.clock += 3
        controller.automaticallyWake(preferences)
        #expect(sender.sent.count == 4)
    }

    @Test func automaticFailuresAndCancellationNeverRequireInteraction() async {
        let sender = RecordingWakeSender(fails: true)
        let access = ProAccessController.testing(status: .free)
        let free = WakeOnLANController(sender: sender)
        let preferences = WakeOnLANPreferences(macAddress: "02:11:22:33:44:55", automaticallyWake: true)
        free.automaticallyWake(preferences)
        #expect(!access.isPaywallPresented)
        let controller = WakeOnLANController(sender: sender)
        var failures = 0
        controller.reportAutomaticFailure = { _ in failures += 1 }
        controller.automaticallyWake(preferences)
        #expect(failures == 1)
        let task = Task { @MainActor in
            await Task.yield()
            controller.automaticallyWake(.init(macAddress: "02:11:22:33:44:66", automaticallyWake: true))
        }
        task.cancel()
        await task.value
        #expect(failures == 1)
    }

    @Test func connectionSnapshotsReadLatestWakePreferencesForTargetAndJump() async throws {
        let identity = Identity(name: "Login", username: "user")
        var jump = Host(name: "Jump", host: "jump.invalid", identityID: identity.id)
        var target = Host(name: "Target", host: "target.invalid", identityID: identity.id)
        target.jumpHostID = jump.id
        let library = HostLibraryModel(hosts: [jump, target], identities: [identity])
        let sender = RecordingWakeSender()
        library.wakeOnLAN = WakeOnLANController(sender: sender)
        let preparation = try library.prepareSSHConnection(for: target, submissions: [:])
        let configuration = try await preparation.resolve(trustPolicy: .allowChallenge)
        jump.wakeOnLAN = .init(macAddress: "02:11:22:33:44:55", automaticallyWake: true)
        target.wakeOnLAN = .init(macAddress: "02:11:22:33:44:66", automaticallyWake: true)
        library.upsert(jump)
        library.upsert(target)
        await configuration.beforeConnect?()
        #expect(sender.sent.map(\.rawValue) == ["02:11:22:33:44:55", "02:11:22:33:44:66"])
        let direct = try library.sshConnectionConfiguration(for: target, trustPolicy: .allowChallenge)
        #expect(direct.beforeConnect != nil)
        let snapshot = SSHAdditionalConnectionSnapshot(configuration: direct)
        let additional = try library.additionalConnectionRequest(from: snapshot)
        #expect(additional.configuration.beforeConnect != nil)
        let resumed = try await library.resumableRouteRequest(
            from: snapshot, authorizeHostKey: nil, keyboardInteractive: nil,
            securityKeySigning: nil, hostKeyConstraints: [:])
        #expect(resumed.configuration.beforeConnect != nil)
        target.telnetEnabled = true
        let telnet = try library.telnetConnectionConfiguration(for: target)
        #expect(telnet.beforeConnect != nil)
    }

    @Test func broadcastAndProbeScopeHonorSmallSubnetsAndCapLargeSubnets() {
        let wide = LocalIPv4Interface(address: 0xC0A8_1234, mask: 0xFFFF_0000)
        #expect(wide.broadcast == 0xC0A8_FFFF)
        #expect(wide.scanAddresses.count == 253)
        #expect(wide.scanAddresses.first == "192.168.18.1")
        #expect(wide.scanAddresses.last == "192.168.18.254")
        #expect(!wide.scanAddresses.contains("192.168.18.52"))
        let narrow = LocalIPv4Interface(address: 0xC0A8_1205, mask: 0xFFFF_FFFC)
        #expect(narrow.scanAddresses == ["192.168.18.6"])
        #expect(narrow.broadcast == 0xC0A8_1207)
    }

    @Test func probesRequireACompleteSSHIdentificationAndMergeByAddressAndPort() {
        #expect(!SSHIdentification.isPresent(in: Data("HTTP/1.1 200 OK\r\n".utf8)))
        #expect(!SSHIdentification.isPresent(in: Data("SSH-2.0-OpenSSH".utf8)))
        #expect(SSHIdentification.isPresent(in: Data("Welcome\r\nSSH-2.0-OpenSSH_9.0\r\n".utf8)))
        #expect(!SSHIdentification.isPresent(in: Data("SSH-2.0-\r\n".utf8)))
        let discovered = DiscoveredLocalHost(
            name: "Mac", address: "mac.local.", port: 22, source: .bonjour,
            resolvedAddresses: ["192.168.1.3", "fe80::1%en0"])
        let probe = DiscoveredLocalHost(name: "192.168.1.3", address: "192.168.1.3", port: 22, source: .probe)
        var otherPort = discovered
        otherPort.port = 2222
        let merged = DiscoveredLocalHost.merged([probe, discovered, otherPort])
        #expect(merged.count == 2)
        #expect(merged.allSatisfy { $0.source == .bonjour })
    }

    @Test func prefillPreservesOtherDraftFieldsAndNeverReplacesManagedAddresses() {
        var host = Host(name: "Draft", host: "before.invalid", groupID: UUID(), tags: ["Test"])
        host.wakeOnLAN.macAddress = "02:11:22:33:44:55"
        let groupID = host.groupID
        let discovered = DiscoveredLocalHost(name: "Found", address: "192.168.1.3", port: 2222, source: .bonjour)
        discovered.prefill(&host)
        #expect(host.host == "192.168.1.3")
        #expect(host.sshPort == 2222)
        #expect(host.groupID == groupID && host.tags == ["Test"])
        #expect(host.wakeOnLAN.macAddress == "02:11:22:33:44:55")
        host.tailscale = .init(groupID: UUID(), stableNodeID: "node")
        let managed = host
        discovered.prefill(&host)
        #expect(host == managed)
    }

    @Test func telnetDiscoveryScansPort23WithoutSSHBonjourOrBanner() {
        let telnet = LocalDiscoveryProbePolicy(connectionProtocol: .telnet)
        let ssh = LocalDiscoveryProbePolicy(connectionProtocol: .ssh)
        #expect(telnet.port == 23)
        #expect(telnet.bonjourServices.isEmpty)
        #expect(telnet.acceptsConnection(received: Data()))
        #expect(telnet.acceptsConnection(received: Data([255, 253, 24])))
        #expect(ssh.port == 22)
        #expect(ssh.bonjourServices == ["_ssh._tcp", "_sftp-ssh._tcp"])
        #expect(!ssh.acceptsConnection(received: Data()))
        #expect(!ssh.acceptsConnection(received: Data([255, 253, 24])))
        #expect(ssh.acceptsConnection(received: Data("SSH-2.0-OpenSSH_9.0\r\n".utf8)))
        #expect(LocalDiscoveryProtocol(terminalProtocol: .telnet) == .telnet)
        #expect(LocalDiscoveryProtocol(terminalProtocol: .ssh) == .ssh)
        #expect(LocalDiscoveryProtocol(terminalProtocol: .mosh) == nil)
        #expect(LocalDiscoveryProtocol(terminalProtocol: .eternalTerminal) == nil)
    }

    @Test func telnetPrefillEnablesOnlyTelnetAndPreservesSSHAndOtherDraftSettings() {
        var host = Host(name: "Draft", host: "old.invalid", groupID: UUID(), tags: ["Lab"])
        host.sshEnabled = false
        host.sshPort = 2222
        host.telnetPort = 2323
        host.wakeOnLAN.macAddress = "02:11:22:33:44:55"
        let original = host
        let discovered = DiscoveredLocalHost(
            name: "Router", address: "192.168.1.1", port: 23, source: .probe, connectionProtocol: .telnet)
        discovered.prefill(&host)
        #expect(host.name == "Router" && host.host == "192.168.1.1")
        #expect(host.telnetEnabled && host.telnetPort == 23)
        #expect(!host.sshEnabled && host.sshPort == 2222)
        #expect(host.preferredTerminalProtocol == .telnet)
        #expect(host.id == original.id && host.groupID == original.groupID && host.tags == original.tags)
        #expect(host.wakeOnLAN == original.wakeOnLAN)
        host.tailscale = .init(groupID: UUID(), stableNodeID: "node")
        let managed = host
        discovered.prefill(&host)
        #expect(host == managed)
    }

    @Test func discoveryDoesNotMergeDifferentProtocolsAtTheSameEndpoint() {
        let ssh = DiscoveredLocalHost(name: "Router", address: "192.168.1.1", port: 23, source: .probe)
        var telnet = ssh
        telnet.connectionProtocol = .telnet
        #expect(ssh.id != telnet.id)
        #expect(DiscoveredLocalHost.merged([ssh, telnet, telnet]).count == 2)
    }

    @Test func remoteMACParsingRejectsMalformedAndDuplicateCandidates() {
        let result = SSHHostMACAddressResolver.parse(
            "en0|02:11:22:33:44:55\nen1|02-11-22-33-44-55\nlo|00:00:00:00:00:00\nbad|FF:FF:FF:FF:FF:FF\nerror\n")
        #expect(result.count == 1)
        #expect(result.first?.interface == "en0")
    }

    @Test func legacyStoreMigratesAndWakePreferencesSurviveReopening() throws {
        var host = Host(name: "Host", host: "server.invalid")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store")
        do {
            let schema = Schema(versionedSchema: TermindSchemaV55.self)
            let legacy = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none))
            legacy.mainContext.insert(TermindSchemaV55HostModels.PersistentHost(host))
            try legacy.mainContext.save()
        }
        do {
            let container = try TermindPersistence.makeContainer(url: url)
            let store = HostPersistence(context: container.mainContext)
            #expect(try store.load().hosts == [host])
            host.wakeOnLAN = .init(macAddress: "02:11:22:33:44:55", automaticallyWake: true)
            _ = try store.save(.init(hosts: [host]))
        }
        let reopened = try TermindPersistence.makeContainer(url: url)
        #expect(try HostPersistence(context: reopened.mainContext).load().hosts == [host])
    }

    @Test func wireProtectsWakePreferencesAndLegacyDomainDefaultsAreSafe() throws {
        var host = Host(name: "Host", host: "server.invalid")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
        json.removeValue(forKey: "wakeOnLAN")
        let legacy = try JSONDecoder().decode(Host.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.wakeOnLAN == .init())
        host.wakeOnLAN = .init(macAddress: "02:11:22:33:44:55", automaticallyWake: true)
        let payload = VaultRecordPayload.host(host)
        let envelope = VaultEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        #expect(try VaultSyncCodec.decode(VaultSyncCodec.encode(envelope)) == envelope)
        for version in [1, 2, 4, 5, 6] {
            var old = envelope
            old.formatVersion = version
            #expect(throws: (any Error).self) { try VaultSyncCodec.encode(old) }
        }
    }

    @Test func tailscaleWakePreferencesSurviveProjectionSavingAndWireRoundtrip() throws {
        var group = HostGroup(name: "Tailnet")
        group.tailscale = TailscaleGroupConfiguration(
            network: try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "test.ts.net"))
        let peer = TailscalePeer(
            stableID: "peer", name: "Server", dnsName: "server.test.ts.net", online: true,
            sshHostKeys: ["ssh-ed25519 test"])
        let library = HostLibraryModel(groups: [group])
        library.replaceTailscalePeers([peer], groupID: group.id)
        var host = try #require(library.hosts.first)
        host.wakeOnLAN = .init(macAddress: "02:11:22:33:44:55", automaticallyWake: true)
        #expect(library.saveTailscaleHost(host))
        library.replaceTailscalePeers([peer], groupID: group.id)
        #expect(library.host(host.id)?.wakeOnLAN == host.wakeOnLAN)
        let payload = VaultRecordPayload.hostGroup(try #require(library.group(group.id)))
        let envelope = VaultEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        #expect(try VaultSyncCodec.decode(VaultSyncCodec.encode(envelope)) == envelope)
        var old = envelope
        old.formatVersion = 6
        #expect(throws: (any Error).self) { try VaultSyncCodec.encode(old) }
    }

    @Test func v7GroupWakeOverridesRoundTripManyPeersAndRejectInvalidKeys() throws {
        var group = HostGroup(name: "Large Tailnet")
        var configuration = TailscaleGroupConfiguration(
            network: try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "test.ts.net"))
        for index in 0..<128 {
            let id = try #require(UUID(uuidString: String(format: "aaaaaaaa-aaaa-aaaa-aaaa-%012x", index)))
            var preferences = TailscaleHostPreferences()
            preferences.username = "peer-\(index)"
            preferences.terminalTransports.eternalTerminalEnabled = index.isMultiple(of: 2)
            preferences.terminalTransports.eternalTerminalPort = 2022 + index
            preferences.wakeOnLAN = .init(
                macAddress: String(format: "02:11:22:33:44:%02X", index), automaticallyWake: index.isMultiple(of: 2))
            configuration.hostPreferences[id] = preferences
        }
        group.tailscale = configuration
        let payload = VaultRecordPayload.hostGroup(group)
        let envelope = VaultEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        let encoded = try VaultSyncCodec.encode(envelope)
        #expect(try VaultSyncCodec.decode(encoded) == envelope)
        let validKey = "aaaaaaaa-aaaa-aaaa-aaaa-000000000000"
        for invalidKey in [validKey.uppercased(), "not-a-uuid", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"] {
            var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            var payloadJSON = try #require(json["payload"] as? [String: Any])
            var groupJSON = try #require(payloadJSON["hostGroup"] as? [String: Any])
            var value = try #require(groupJSON["_0"] as? [String: Any])
            var wake = try #require(value["wakeOnLAN"] as? [String: Any])
            let preferencesJSON = try #require(wake[validKey] as? [String: Any])
            wake.removeValue(forKey: validKey)
            wake[invalidKey] = preferencesJSON
            value["wakeOnLAN"] = wake
            groupJSON["_0"] = value
            payloadJSON["hostGroup"] = groupJSON
            json["payload"] = payloadJSON
            let invalid = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: (any Error).self) { try VaultSyncCodec.decode(invalid) }
        }
    }

    @Test func invalidWakePreferencesCannotMutateManagedHostPreferences() throws {
        var group = HostGroup(name: "Tailnet")
        group.tailscale = TailscaleGroupConfiguration(
            network: try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "test.ts.net"))
        let peer = TailscalePeer(
            stableID: "peer", name: "Server", dnsName: "server.test.ts.net", online: true,
            sshHostKeys: ["ssh-ed25519 test"])
        let library = HostLibraryModel(groups: [group])
        library.replaceTailscalePeers([peer], groupID: group.id)
        var original = try #require(library.hosts.first)
        original.wakeOnLAN = .init(macAddress: "02:11:22:33:44:55", automaticallyWake: true)
        #expect(library.saveTailscaleHost(original, username: "original"))
        let savedGroup = try #require(library.group(group.id))
        for preferences in [
            WakeOnLANPreferences(macAddress: "", automaticallyWake: true),
            WakeOnLANPreferences(macAddress: "02:11:22:33:44:GG"),
        ] {
            var draft = original
            draft.wakeOnLAN = preferences
            draft.iconOverrideID = "cloud"
            #expect(!library.saveTailscaleHost(draft, username: "unsaved"))
            #expect(!library.saveHost(draft))
            #expect(library.group(group.id) == savedGroup)
            #expect(library.host(original.id) == original)
        }
        original.wakeOnLAN = .init()
        #expect(library.saveTailscaleHost(original, username: "corrected"))
        library.replaceTailscalePeers([peer], groupID: group.id)
        #expect(library.host(original.id)?.wakeOnLAN == .init())
        #expect(library.tailscaleUsername(for: original) == "corrected")
    }
}

private nonisolated final class RecordingWakeSender: WakeOnLANSending, @unchecked Sendable {
    private let lock = NSLock()
    private var addresses: [MACAddress] = []
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    var sent: [MACAddress] { lock.withLock { addresses } }
    func send(to address: MACAddress) throws {
        if fails { throw WakeOnLANError.noLocalNetwork }
        lock.withLock { addresses.append(address) }
    }
}

@MainActor
private final class WakeTestState {
    var clock = 10.0
}
