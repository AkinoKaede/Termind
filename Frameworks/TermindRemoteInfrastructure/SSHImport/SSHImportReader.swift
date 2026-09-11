import Foundation
import TermindApplication
import TermindDomain

/// One import session owns its secrets. Only metadata leaves this actor until commit.
public actor SSHImportReader: SSHImportReading {
    private let username: String
    private let home: URL?

    public init(username: String, home: URL? = nil) {
        self.username = username
        self.home = home
    }

    private struct Material {
        var text: String
        var certificate: String
    }
    private var materials: [UUID: Material] = [:]
    private var stableIDs: [String: UUID] = [:]

    public func discard() { materials.removeAll() }

    public func scan(root: URL, knownHostsOnly: Bool, grants: [URL] = []) throws -> [SSHImportItem] {
        let scopes = [root] + grants
        let acquired = scopes.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in acquired { url.stopAccessingSecurityScopedResource() } }
        materials.removeAll()
        let sourceType = try root.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        guard knownHostsOnly ? sourceType.isRegularFile == true : sourceType.isDirectory == true else {
            throw knownHostsOnly ? SSHImportSourceError.expectedFile : SSHImportSourceError.expectedFolder
        }
        if knownHostsOnly {
            return stabilize(SSHImportParser.knownHosts(try read(root), source: root.path))
        }
        let root = root.standardizedFileURL
        let authorized = scopes.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        func allowed(_ url: URL) -> Bool {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            return authorized.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        var files: [String: String] = [:]
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
                    at: scope, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [])
                urls = enumerator?.allObjects.compactMap { $0 as? URL } ?? []
            } else {
                urls = [scope]
            }
            for url in urls {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isRegularFile == true || values?.isSymbolicLink == true else { continue }
                guard allowed(url) else {
                    inaccessible.append(url.path)
                    continue
                }
                fileCount += 1
                guard fileCount <= 4096 else { throw CocoaError(.fileReadTooLarge) }
                do {
                    let value = try read(url)
                    totalBytes += value.utf8.count
                    guard totalBytes <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    files[url.standardizedFileURL.path] = value
                } catch {
                    inaccessible.append(url.path)
                }
            }
        }
        var parser = SSHConfigParser(
            root: root, home: home ?? root.deletingLastPathComponent(),
            username: username, files: files)
        var items = parser.parse()
        let knownPath = root.appendingPathComponent("known_hosts").path
        if let known = files[knownPath] { items += SSHImportParser.knownHosts(known, source: knownPath) }
        let hosts = items.compactMap(\.host)
        let referenced = Set(hosts.flatMap(\.identityPaths))
        let privateFiles = files.keys.filter { isPrivateKey(files[$0] ?? "") }
        let paths = Set(privateFiles).union(referenced.filter { files[$0] != nil })
        for path in paths.sorted() {
            let content = files[path] ?? ""
            guard isPrivateKey(content) else {
                items.append(
                    SSHImportItem(
                        category: .keys, name: URL(fileURLWithPath: path).lastPathComponent,
                        source: path, selected: false,
                        issue: String(localized: "No supported private key in this file."), unavailable: true))
                continue
            }
            let explicitCertificates = hosts.filter { $0.identityPaths.contains(path) }.flatMap(\.certificatePaths)
            let certificatePaths = Set(explicitCertificates + [path + "-cert.pub"])
            var variants: [String: [String]] = [:]
            for certificatePath in certificatePaths.sorted() {
                if let certificate = files[certificatePath] {
                    variants[certificate, default: []].append(certificatePath)
                }
            }
            if files[path + "-cert.pub"] == nil { variants[""] = [] }
            for certificate in variants.keys.sorted() {
                let stable = path + "\n" + certificate
                let id = stableID(stable)
                materials[id] = Material(text: content, certificate: certificate)
                var item = SSHImportItem(
                    id: id, category: .keys, name: URL(fileURLWithPath: path).lastPathComponent, source: path)
                item.certificatePaths = variants[certificate] ?? []
                do {
                    item.key = try inspect(id: id, name: item.name, passphrase: nil)
                } catch {
                    if isEncrypted(content) {
                        item.requiresPassphrase = true
                        item.issue = String(localized: "Enter the key passphrase to validate this private key.")
                    } else {
                        item.selected = false
                        item.unavailable = true
                        item.issue = String(localized: "No supported private key in this file.")
                    }
                }
                items.append(item)
            }
        }
        let missing = hosts.filter { !$0.usesDefaultIdentityFiles }.flatMap(\.identityPaths).filter { files[$0] == nil }
        let certificateMissing = hosts.flatMap(\.certificatePaths).filter { files[$0] == nil }
        for path in Set(inaccessible).union(parser.externalPaths).union(missing).union(certificateMissing).sorted() {
            items.append(
                SSHImportItem(
                    category: path == knownPath ? .knownHosts : parser.externalPaths.contains(path) ? .hosts : .keys,
                    name: URL(fileURLWithPath: path).lastPathComponent, source: path,
                    issue: String(localized: "Authorize access to this referenced file, or deselect it."),
                    needsAuthorization: path))
        }
        // Missing explicit references must also be visible on the affected host.
        for index in items.indices {
            guard let host = items[index].host else { continue }
            let absent = (host.identityPaths + host.certificatePaths).filter {
                files[$0] == nil && !(host.usesDefaultIdentityFiles && host.identityPaths.contains($0))
            }
            items[index].warnings += absent.map { String(localized: "Referenced file is unavailable:") + " " + $0 }
        }
        return stabilize(items)
    }

    public func unlock(id: UUID, name: String, passphrase: String) throws -> SSHKeyRef {
        try inspect(id: id, name: name, passphrase: passphrase)
    }

    public func credentials(for ids: Set<UUID>) throws -> [UUID: StoredSSHKeyCredential] {
        var result: [UUID: StoredSSHKeyCredential] = [:]
        for id in ids {
            guard let material = materials[id] else { throw CocoaError(.fileReadUnknown) }
            result[id] = .software(SSHPrivateKeySecret(privateKey: material.text))
        }
        return result
    }

    private func inspect(id: UUID, name: String, passphrase: String?) throws -> SSHKeyRef {
        guard let input = materials[id] else { throw CocoaError(.fileReadUnknown) }
        let material = try SSHKeyMaterial.inspect(privateKey: input.text, passphrase: passphrase)
        if !input.certificate.isEmpty {
            _ = try SSHUserCertificate.parse(input.certificate, matching: material.publicKey)
        }
        return SSHKeyRef(
            id: id, label: name, algorithm: material.algorithm,
            publicKey: material.publicKey, certificate: input.certificate, fingerprint: material.fingerprint,
            credentialRef: "termind.key.\(id.uuidString)", storage: .iCloud, keySize: material.keySize,
            hasPassphrase: passphrase?.isEmpty == false, createdAt: Date())
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
            if materials[item.id] == nil {
                let token = "\(item.category.rawValue):\(item.source):\(item.name)"
                let occurrence = occurrences[token, default: 0]
                occurrences[token] = occurrence + 1
                item.id = stableID(token + ":\(occurrence)")
            }
            return item
        }
    }

    private func read(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 8 * 1024 * 1024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        return try String(contentsOf: url, encoding: .utf8)
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

    private func isPrivateKey(_ text: String) -> Bool {
        [
            "-----BEGIN OPENSSH PRIVATE KEY-----", "-----BEGIN RSA PRIVATE KEY-----", "-----BEGIN EC PRIVATE KEY-----",
            "-----BEGIN PRIVATE KEY-----", "-----BEGIN ENCRYPTED PRIVATE KEY-----", "-----BEGIN DSA PRIVATE KEY-----",
        ].contains { text.hasPrefix($0) }
    }

}
