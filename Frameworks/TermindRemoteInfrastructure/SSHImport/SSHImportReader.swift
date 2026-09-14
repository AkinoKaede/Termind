import CryptoKit
import Foundation
import TermindApplication
import TermindDomain

/// One import session owns only source descriptors and public metadata. Private
/// key text is read inside scan, unlock, or commit and never becomes actor state.
public actor SSHImportReader: SSHImportReading {
    private let username: String
    private let home: URL?

    public init(username: String, home: URL? = nil) {
        self.username = username
        self.home = home
    }

    private struct KeySource {
        let url: URL
        let digest: Data
    }

    private struct KeyCandidate {
        let url: URL
        let path: String
        let digest: Data
        let encrypted: Bool
    }

    private struct CertificateSource {
        let path: String
        let text: String
    }

    private struct FilePayload {
        let text: String
        let digest: Data
    }

    private var keySources: [UUID: KeySource] = [:]
    private var certificateSources: [CertificateSource] = []
    private var accessScopes: [URL] = []
    private var stableIDs: [String: UUID] = [:]

    public func discard() {
        keySources.removeAll()
        certificateSources.removeAll()
        accessScopes.removeAll()
    }

    public func scan(root: URL, knownHostsOnly: Bool, grants: [URL] = []) throws -> [SSHImportItem] {
        discard()
        let scopes = [root] + grants
        accessScopes = scopes
        let acquired = scopes.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in acquired { url.stopAccessingSecurityScopedResource() } }

        let sourceType = try root.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        guard knownHostsOnly ? sourceType.isRegularFile == true : sourceType.isDirectory == true else {
            throw knownHostsOnly ? SSHImportSourceError.expectedFile : SSHImportSourceError.expectedFolder
        }
        if knownHostsOnly {
            let payload = try readPayload(root)
            let kind = SSHImportParser.contentKind(payload.text)
            guard kind == .knownHosts || containsOnlyCommentsAndWhitespace(payload.text) else {
                throw SSHImportSourceError.unsupportedKnownHostsContent
            }
            return stabilize(SSHImportParser.knownHosts(payload.text, source: root.path))
        }

        let standardizedRoot = root.standardizedFileURL
        let authorized = scopes.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        func allowed(_ url: URL) -> Bool {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            return authorized.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        var configurationFiles: [String: String] = [:]
        var knownHostItems: [SSHImportItem] = []
        var keyCandidates: [String: KeyCandidate] = [:]
        var contentKinds: [String: SSHImportContentKind] = [:]
        var availablePaths: Set<String> = []
        var inaccessible: [String] = []
        var fileCount = 0
        var totalBytes = 0
        let manager = FileManager.default

        for scope in scopes {
            var directory: ObjCBool = false
            guard manager.fileExists(atPath: scope.path, isDirectory: &directory) else { continue }
            let urls: [URL]
            if directory.boolValue {
                let enumerator = manager.enumerator(
                    at: scope,
                    includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
                    options: [])
                urls = enumerator?.allObjects.compactMap { $0 as? URL } ?? []
            } else {
                urls = [scope]
            }
            for url in urls {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isRegularFile == true || values?.isSymbolicLink == true else { continue }
                guard allowed(url) else {
                    inaccessible.append(url.path)
                    continue
                }
                fileCount += 1
                guard fileCount <= 4_096 else { throw CocoaError(.fileReadTooLarge) }
                let fileSize = values?.fileSize ?? 0
                totalBytes += fileSize
                guard fileSize <= 8 * 1_024 * 1_024, totalBytes <= 64 * 1_024 * 1_024 else {
                    throw CocoaError(.fileReadTooLarge)
                }
                let path = url.standardizedFileURL.path
                do {
                    let payload = try readPayload(url)
                    let kind = SSHImportParser.contentKind(payload.text)
                    availablePaths.insert(path)
                    contentKinds[path] = kind
                    switch kind {
                    case .privateKey:
                        keyCandidates[path] = KeyCandidate(
                            url: url, path: path, digest: payload.digest,
                            encrypted: isEncrypted(payload.text))
                    case .userCertificate:
                        certificateSources.append(
                            CertificateSource(
                                path: path,
                                text: payload.text.trimmingCharacters(in: .whitespacesAndNewlines)))
                    case .knownHosts:
                        knownHostItems += SSHImportParser.knownHosts(payload.text, source: path)
                    case .configuration:
                        configurationFiles[path] = payload.text
                    case .unknown:
                        break
                    }
                } catch {
                    inaccessible.append(path)
                }
            }
        }

        var parser = SSHConfigParser(
            root: standardizedRoot, home: home ?? standardizedRoot.deletingLastPathComponent(),
            username: username, files: configurationFiles,
            entryPaths: configurationFiles.keys.sorted())
        var items = parser.parse() + knownHostItems
        let hosts = items.compactMap(\.host)
        let referencedKeys = Set(hosts.flatMap(\.identityPaths))

        for path in Set(keyCandidates.keys).union(referencedKeys).sorted() {
            guard let candidate = keyCandidates[path] else {
                if availablePaths.contains(path), contentKinds[path] != .privateKey {
                    items.append(
                        SSHImportItem(
                            category: .keys, name: URL(fileURLWithPath: path).lastPathComponent,
                            source: path, selected: false,
                            issue: String(localized: "No supported private key in this file."), unavailable: true))
                }
                continue
            }
            if candidate.encrypted {
                let id = stableID(path + "\n")
                keySources[id] = KeySource(url: candidate.url, digest: candidate.digest)
                items.append(
                    SSHImportItem(
                        id: id, category: .keys, name: URL(fileURLWithPath: path).lastPathComponent,
                        source: path,
                        issue: String(localized: "Enter the key passphrase to validate this private key."),
                        requiresPassphrase: true))
                continue
            }
            do {
                let material = try inspect(candidate, passphrase: nil)
                items += makeKeyItems(candidate: candidate, material: material)
            } catch {
                items.append(
                    SSHImportItem(
                        category: .keys, name: URL(fileURLWithPath: path).lastPathComponent,
                        source: path, selected: false,
                        issue: String(localized: "No supported private key in this file."), unavailable: true))
            }
        }

        let missingKeys = hosts.filter { !$0.usesDefaultIdentityFiles }.flatMap(\.identityPaths).filter {
            !availablePaths.contains($0)
        }
        let missingCertificates = hosts.flatMap(\.certificatePaths).filter { !availablePaths.contains($0) }
        for path in Set(inaccessible).union(parser.externalPaths).union(missingKeys).union(missingCertificates).sorted()
        {
            items.append(
                SSHImportItem(
                    category: parser.externalPaths.contains(path) ? .hosts : .keys,
                    name: URL(fileURLWithPath: path).lastPathComponent, source: path,
                    issue: String(localized: "Authorize access to this referenced file, or deselect it."),
                    needsAuthorization: path))
        }

        // Missing explicit references must also be visible on the affected host.
        for index in items.indices {
            guard let host = items[index].host else { continue }
            let absent = (host.identityPaths + host.certificatePaths).filter {
                !availablePaths.contains($0) && !(host.usesDefaultIdentityFiles && host.identityPaths.contains($0))
            }
            items[index].warnings += absent.map { String(localized: "Referenced file is unavailable:") + " " + $0 }
        }
        return stabilize(items)
    }

    public func unlock(id: UUID, name: String, passphrase: String) throws -> [SSHImportItem] {
        guard let source = keySources[id] else { throw CocoaError(.fileReadUnknown) }
        return try withAccess {
            let payload = try readPayload(source.url)
            guard payload.digest == source.digest, SSHImportParser.contentKind(payload.text) == .privateKey else {
                throw SSHImportSourceError.sourceChanged
            }
            let material = try SSHKeyMaterial.inspect(privateKey: payload.text, passphrase: passphrase)
            let candidate = KeyCandidate(
                url: source.url, path: source.url.standardizedFileURL.path,
                digest: source.digest, encrypted: true)
            keySources.removeValue(forKey: id)
            return makeKeyItems(candidate: candidate, material: material, name: name, hasPassphrase: true)
        }
    }

    public func credentials(for ids: Set<UUID>) throws -> [UUID: StoredSSHKeyCredential] {
        try withAccess {
            var result: [UUID: StoredSSHKeyCredential] = [:]
            for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let source = keySources[id] else { throw CocoaError(.fileReadUnknown) }
                let payload = try readPayload(source.url)
                guard payload.digest == source.digest, SSHImportParser.contentKind(payload.text) == .privateKey else {
                    throw SSHImportSourceError.sourceChanged
                }
                result[id] = .software(SSHPrivateKeySecret(privateKey: payload.text))
            }
            return result
        }
    }

    private func inspect(_ candidate: KeyCandidate, passphrase: String?) throws -> SSHKeyMaterial {
        try withAccess {
            let payload = try readPayload(candidate.url)
            guard payload.digest == candidate.digest else { throw SSHImportSourceError.sourceChanged }
            return try SSHKeyMaterial.inspect(privateKey: payload.text, passphrase: passphrase)
        }
    }

    private func makeKeyItems(
        candidate: KeyCandidate, material: SSHKeyMaterial, name: String? = nil, hasPassphrase: Bool = false
    ) -> [SSHImportItem] {
        var variants: [String: [String]] = [:]
        for certificate in certificateSources {
            if (try? SSHUserCertificate.parse(certificate.text, matching: material.publicKey)) != nil {
                variants[certificate.text, default: []].append(certificate.path)
            }
        }
        // The private key remains a valid variant in its own right. Hosts with
        // an explicit CertificateFile select the matching certificate path;
        // hosts without one continue to use the bare key.
        variants[""] = []
        return variants.keys.sorted().map { certificate in
            let id = stableID(candidate.path + "\n" + certificate)
            keySources[id] = KeySource(url: candidate.url, digest: candidate.digest)
            let label = name ?? URL(fileURLWithPath: candidate.path).lastPathComponent
            let key = SSHKeyRef(
                id: id, label: label, algorithm: material.algorithm,
                publicKey: material.publicKey, certificate: certificate, fingerprint: material.fingerprint,
                credentialRef: "termind.key.\(id.uuidString)", storage: .iCloud, keySize: material.keySize,
                hasPassphrase: hasPassphrase, createdAt: Date())
            return SSHImportItem(
                id: id, category: .keys, name: label, source: candidate.path,
                key: key, certificatePaths: variants[certificate] ?? [])
        }
    }

    private func stableID(_ source: String) -> UUID {
        if let id = stableIDs[source] { return id }
        let id = UUID()
        stableIDs[source] = id
        return id
    }

    private func stabilize(_ values: [SSHImportItem]) -> [SSHImportItem] {
        var occurrences: [String: Int] = [:]
        return values.map { item in
            var item = item
            if keySources[item.id] == nil {
                let token = "\(item.category.rawValue):\(item.source):\(item.name)"
                let occurrence = occurrences[token, default: 0]
                occurrences[token] = occurrence + 1
                item.id = stableID(token + ":\(occurrence)")
            }
            return item
        }
    }

    private func withAccess<T>(_ operation: () throws -> T) rethrows -> T {
        let acquired = accessScopes.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in acquired { url.stopAccessingSecurityScopedResource() } }
        return try operation()
    }

    private func readPayload(_ url: URL) throws -> FilePayload {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 8 * 1_024 * 1_024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return FilePayload(text: text, digest: Data(SHA256.hash(data: data)))
    }

    private func containsOnlyCommentsAndWhitespace(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).allSatisfy {
            let line = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty || line.hasPrefix("#")
        }
    }

    private func isEncrypted(_ text: String) -> Bool {
        if text.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") || text.contains("DEK-Info:") { return true }
        guard text.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") else { return false }
        let encoded = text.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        let magic = Data("openssh-key-v1\0".utf8)
        guard let data = Data(base64Encoded: encoded), data.starts(with: magic), data.count >= magic.count + 4 else {
            return false
        }
        let offset = magic.count
        let length = data[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard Int(length) <= data.count - offset - 4 else { return false }
        let cipher = String(data: data.subdata(in: offset + 4..<offset + 4 + Int(length)), encoding: .utf8)
        return cipher != nil && cipher != "none"
    }
}
