import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

nonisolated struct QuickConnectTarget: Hashable, Sendable {
    var host: Host
    var route: SSHConnectionRoute
    var isSaved: Bool
    var connectionProtocol: HostTerminalProtocol

    var username: String? { route.usernames[host.id] }
    var loginAddress: String { address(for: host) }
    var routeSummary: String { route.hosts.map(address).joined(separator: " → ") }

    private func address(for host: Host) -> String {
        let displayAddress = host.displayAddress(for: connectionProtocol)
        guard let username = route.usernames[host.id], !username.isEmpty else { return displayAddress }
        return "\(username)@\(displayAddress)"
    }
}

/// Resolves public Vault metadata only. Credential lookup belongs to Connect.
@MainActor
enum QuickConnectResolver {
    static func resolve(
        _ input: QuickConnectInput, in library: HostLibraryModel, locale: Locale = .current
    ) throws -> QuickConnectTarget {
        if input.connectionProtocol == .telnet {
            return try resolveTelnet(input, in: library, locale: locale)
        }
        var usernames: [Host.ID: String] = [:]
        var originals: [Host.ID: Host] = [:]

        func resolveEndpoint(_ endpoint: QuickConnectInput.Endpoint) throws -> Host {
            let matches = input.isCommand ? library.hosts.filter { $0.name == endpoint.host } : []
            guard matches.count <= 1 else {
                throw TermindSSHError.route(
                    AppLocalization.resolve(
                        TermindCopy.Connections.moreThanOneSavedHostIsNamed(endpoint.host), locale: locale))
            }
            if matches.isEmpty, endpoint.host.contains(where: \.isWhitespace) {
                throw TermindSSHError.route(
                    AppLocalization.resolve(TermindCopy.Connections.invalidSshDestination, locale: locale))
            }
            var host = matches.first ?? Host(name: endpoint.host, host: endpoint.host)
            if let original = matches.first { originals[host.id] = original }
            if let port = endpoint.port { host.port = port }
            if let username = endpoint.username {
                if library.identity(for: host)?.username != username {
                    let identities = library.reusableIdentities.filter { $0.username == username }
                    host.identityID = identities.count == 1 ? identities.first?.id : nil
                }
                usernames[host.id] = username
            } else if let username = library.identity(for: host)?.username {
                usernames[host.id] = username
            }
            return host
        }

        func inheritedRoute(_ host: Host) throws -> [Host] {
            guard let route = library.validatedRoute(for: host) else { throw SSHConnectionRoute.invalidRouteError }
            for node in route.dropLast() {
                originals[node.id] = node
                usernames[node.id] = library.identity(for: node)?.username
            }
            return route
        }

        var destination = try resolveEndpoint(input.destination)
        if let hostname = input.hostname {
            guard !hostname.contains(where: \.isWhitespace) else {
                throw TermindSSHError.route(
                    AppLocalization.resolve(TermindCopy.Connections.invalidSshDestination, locale: locale))
            }
            destination.host = hostname
        }
        var nodes: [Host]
        if let jumps = input.jumps {
            nodes = []
            for (index, endpoint) in jumps.enumerated() {
                let jump = try resolveEndpoint(endpoint)
                if index == 0 {
                    nodes += try inheritedRoute(jump)
                } else {
                    nodes.append(jump)
                }
            }
            nodes.append(destination)
        } else {
            nodes = try inheritedRoute(destination)
        }
        // Check source IDs before copying modified records; cloning must never
        // turn an alias cycle into an apparently distinct sequence of Hosts.
        guard nodes.count <= 8, Set(nodes.map(\.id)).count == nodes.count else {
            throw SSHConnectionRoute.invalidRouteError
        }
        var resolved: [Host] = []
        var resolvedUsernames: [Host.ID: String] = [:]
        var sourceIDs: [Host.ID: Host.ID] = [:]
        for var node in nodes {
            let oldID = node.id
            node.jumpHostID = resolved.last?.id
            if let original = originals[oldID] {
                if node != original || usernames[oldID] != library.identity(for: original)?.username {
                    node.id = UUID()
                }
                sourceIDs[node.id] = original.id
            }
            resolvedUsernames[node.id] = usernames[oldID]
            resolved.append(node)
        }
        let host = resolved[resolved.count - 1]
        return QuickConnectTarget(
            host: host,
            route: SSHConnectionRoute(hosts: resolved, usernames: resolvedUsernames, sourceHostIDs: sourceIDs),
            isSaved: library.host(host.id) == host,
            connectionProtocol: .ssh
        )
    }

    private static func resolveTelnet(
        _ input: QuickConnectInput, in library: HostLibraryModel, locale: Locale
    ) throws -> QuickConnectTarget {
        let matches = library.hosts.filter { $0.name == input.destination.host }
        guard matches.count <= 1 else {
            throw TermindSSHError.route(
                AppLocalization.resolve(
                    TermindCopy.Connections.moreThanOneSavedHostIsNamed(input.destination.host), locale: locale))
        }
        var host =
            matches.first
            ?? Host(
                name: input.destination.host, host: input.destination.host,
                sshEnabled: false, telnetEnabled: true)
        if matches.first != nil, !host.telnetEnabled {
            throw HostProtocolUnavailableError(useCase: .telnetTerminal)
        }
        if let port = input.destination.port { host.telnetPort = port }
        var usernames: [Host.ID: String] = [:]
        if let username = input.destination.username {
            let identities = library.reusableIdentities.filter {
                $0.username == username && library.isProxyEligibleOnThisDevice($0)
            }
            host.telnetIdentityID = identities.count == 1 ? identities[0].id : nil
            usernames[host.id] = username
        } else if let username = library.identity(for: host, protocol: .telnet)?.username {
            usernames[host.id] = username
        }
        return QuickConnectTarget(
            host: host, route: SSHConnectionRoute(hosts: [host], usernames: usernames),
            isSaved: library.host(host.id) == host, connectionProtocol: .telnet)
    }
}
