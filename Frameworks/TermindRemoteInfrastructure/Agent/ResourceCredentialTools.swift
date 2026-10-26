// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import TermindDomain

/// Holds consumed capabilities only for one execution, including partial-consumption failures.
nonisolated final class ResourceSecretInputs {
    private var values: [String: AgentSecret] = [:]

    static func consume(_ arguments: ResourceToolArguments, broker: SecretBroker) async throws -> ResourceSecretInputs {
        let result = ResourceSecretInputs()
        do {
            for field in arguments.values.keys.filter({ $0.hasSuffix("_secret_handle") }).sorted() {
                try Task.checkCancellation()
                let handle = SecretHandle(id: try arguments.uuid(field))
                result.values[field] = try await broker.consume(handle)
            }
            try Task.checkCancellation()
            return result
        } catch {
            result.clear()
            throw error
        }
    }

    func string(_ field: String) throws -> String? {
        try values[field]?.withUnsafeBytes { bytes in
            guard bytes.count <= 1_048_576, let value = String(bytes: bytes, encoding: .utf8),
                !value.isEmpty, !value.contains("\0")
            else { throw ResourceToolError.invalidInput }
            return value
        }
    }

    func clear() {
        for value in values.values { value.clear() }
        values.removeAll()
    }

    deinit { clear() }
}

extension AgentResourceManager {
    func manageIdentity(
        _ action: ResourceToolSpecification.Action, _ args: ResourceToolArguments, broker: SecretBroker
    ) async throws -> AgentJSONValue {
        if action == .list {
            return .object(["identities": .array(credentials.managedIdentities.map(ResourceToolOutput.identity))])
        }
        let id = action == .add ? UUID() : try args.uuid("identity_id")
        let original = credentials.managedIdentities.first { $0.id == id }
        guard action == .add || original != nil else { throw ResourceToolError.notFound }
        if action == .get { return ResourceToolOutput.identity(original!) }
        if action == .delete {
            try credentials.deleteManagedIdentity(id)
            return ResourceToolOutput.deleted(id)
        }
        var value = original ?? AgentIdentityInfo(Identity(id: id, name: "", username: ""))
        if original == nil { value.storage = defaultPasswordStorage() }
        value.name = args.text("name") ?? value.name
        value.username = args.text("username") ?? value.username
        value.notes = args.clears.contains("notes") ? "" : args.text("notes") ?? value.notes
        value.color = try args.enumValue("color", default: value.color)
        value.storage = try args.enumValue("storage", default: value.storage)
        value.keyID = args.clears.contains("key_id") ? nil : try args.optionalID("key_id") ?? value.keyID
        guard !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !value.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ResourceToolError.invalidInput }
        if let keyID = value.keyID, !credentials.managedKeys.contains(where: { $0.id == keyID }) {
            throw ResourceToolError.invalidReference
        }
        let inputs = try await ResourceSecretInputs.consume(args, broker: broker)
        defer { inputs.clear() }
        let passwordUpdate: IdentityPasswordUpdate
        if let password = try inputs.string("password_secret_handle") {
            passwordUpdate = .replace(password)
        } else {
            passwordUpdate = args.clears.contains("password") ? .remove : .keep
        }
        try Task.checkCancellation()
        guard credentials.managedIdentities.first(where: { $0.id == id }) == original else {
            throw ResourceToolError.invalidInput
        }
        try credentials.saveManagedIdentity(value, passwordUpdate: passwordUpdate)
        guard let saved = credentials.managedIdentities.first(where: { $0.id == id }) else {
            throw ResourceToolError.saveFailed
        }
        return ResourceToolOutput.identity(saved)
    }

    func manageKey(
        _ action: ResourceToolSpecification.Action, _ args: ResourceToolArguments, broker: SecretBroker
    ) async throws -> AgentJSONValue {
        if action == .list {
            return .object(["keys": .array(credentials.managedKeys.map(ResourceToolOutput.key))])
        }
        let creating = action == .add || action == .generate
        let id = creating ? UUID() : try args.uuid("key_id")
        let original = credentials.managedKeys.first { $0.id == id }
        guard creating || original != nil else { throw ResourceToolError.notFound }
        if action == .get { return ResourceToolOutput.key(original!) }
        if action == .delete {
            try credentials.deleteManagedKey(id)
            return ResourceToolOutput.deleted(id)
        }
        var value =
            original ?? AgentKeyInfo(SSHKeyRef(id: id, label: "", storage: defaultKeyStorage(), createdAt: .now))
        value.label = args.text("label") ?? value.label
        value.color = try args.enumValue("color", default: value.color)
        if let original, original.storage == .secureEnclave || original.algorithm == .securityKey {
            guard Set(args.values.keys).subtracting(["clear_fields"]).isSubset(of: ["key_id", "label", "color"]),
                args.clears.isEmpty
            else {
                throw ResourceToolError.unsupported
            }
            try credentials.saveManagedKey(value, credential: nil, passphraseUpdate: .keep)
            guard let saved = credentials.managedKeys.first(where: { $0.id == id }) else {
                throw ResourceToolError.saveFailed
            }
            return ResourceToolOutput.key(saved)
        }
        value.storage = try args.enumValue("storage", default: value.storage)
        if value.storage == .secureEnclave {
            guard action == .generate,
                args.text("algorithm").map({ $0 == "ecdsa" }) ?? true,
                args.int("bits").map({ $0 == 256 }) ?? true,
                args.text("passphrase_secret_handle") == nil, args.text("certificate") == nil,
                args.bool("save_passphrase") == nil
            else { throw ResourceToolError.unsupported }
        } else if args.bool("requires_user_presence") == true {
            throw ResourceToolError.unsupported
        }
        if args.clears.contains("passphrase"), args.bool("save_passphrase") == true {
            throw ResourceToolError.invalidInput
        }
        let inputs = try await ResourceSecretInputs.consume(args, broker: broker)
        defer { inputs.clear() }
        let passphrase = try inputs.string("passphrase_secret_handle")
        let privateKey = try inputs.string("private_key_secret_handle")
        var credential: StoredSSHKeyCredential?
        var passphraseUpdate: IdentityPasswordUpdate = .keep

        if action == .generate, value.storage == .secureEnclave {
            let generator = generateEnclave
            let presence = args.bool("requires_user_presence") ?? false
            let generated = try await Task.detached(priority: .userInitiated) {
                try generator("termind", presence)
            }.value
            value.algorithm = .ecdsa256
            value.keySize = 256
            value.publicKey = generated.publicKey
            value.fingerprint = generated.fingerprint
            value.requiresUserPresence = presence
            credential = .secureEnclave(generated.credential)
        } else if action == .generate || privateKey != nil {
            let material: SSHKeyMaterial
            if action == .generate {
                let algorithm = args.text("algorithm") ?? "ed25519"
                let generation: SSHKeyMaterial.Generation
                switch algorithm {
                case "ed25519":
                    guard args.int("bits") == nil else { throw ResourceToolError.invalidInput }
                    generation = .ed25519
                case "ecdsa":
                    let bits = args.int("bits") ?? 256
                    guard [256, 384, 521].contains(bits) else { throw ResourceToolError.invalidInput }
                    generation = .ecdsa(bits: bits)
                case "rsa":
                    let bits = args.int("bits") ?? 3072
                    guard [2048, 3072, 4096, 8192].contains(bits) else { throw ResourceToolError.invalidInput }
                    generation = .rsa(bits: bits)
                default: throw ResourceToolError.invalidInput
                }
                material = try await Task.detached(priority: .userInitiated) {
                    try SSHKeyMaterial.generate(generation, comment: "termind", passphrase: passphrase)
                }.value
            } else {
                guard let privateKey else { throw ResourceToolError.invalidInput }
                let suppliedPublic = args.text("public_key") ?? ""
                material = try await Task.detached(priority: .userInitiated) {
                    let metadata = try SSHKeyMaterial.privateKeyMetadata(privateKey)
                    if metadata.isEncrypted && passphrase == nil {
                        // Without unlocking, a supplied public key cannot be verified against the private material.
                        guard suppliedPublic.isEmpty else { throw ResourceToolError.invalidInput }
                        return try SSHKeyMaterial.imported(privateKey: privateKey, publicKey: suppliedPublic)
                    }
                    let inspected = try SSHKeyMaterial.inspect(privateKey: privateKey, passphrase: passphrase)
                    if !suppliedPublic.isEmpty,
                        try SSHKeyMaterial.publicMaterial(suppliedPublic).fingerprint != inspected.fingerprint
                    {
                        throw ResourceToolError.invalidInput
                    }
                    return inspected
                }.value
            }
            value.algorithm = material.algorithm
            value.publicKey = material.publicKey
            value.fingerprint = material.fingerprint
            value.keySize = material.keySize
            value.encrypted = try SSHKeyMaterial.privateKeyMetadata(material.privateKey).isEncrypted
            value.certificate = args.text("certificate") ?? ""
            credential = .software(
                SSHPrivateKeySecret(
                    privateKey: material.privateKey,
                    passphrase: value.encrypted && args.bool("save_passphrase") != false ? passphrase : nil))
        } else {
            guard action == .edit else { throw ResourceToolError.invalidInput }
            if let publicKey = args.text("public_key") {
                let material = try SSHKeyMaterial.publicMaterial(publicKey)
                guard value.publicKey == publicKey || value.fingerprint == material.fingerprint else {
                    throw ResourceToolError.invalidInput
                }
                value.publicKey = material.publicKey
            }
            value.certificate = args.text("certificate") ?? value.certificate
            if let passphrase {
                guard value.encrypted else { throw ResourceToolError.invalidInput }
                passphraseUpdate = args.bool("save_passphrase") == false ? .remove : .replace(passphrase)
            } else if args.clears.contains("passphrase") || args.bool("save_passphrase") == false {
                passphraseUpdate = .remove
            }
        }
        if args.clears.contains("certificate") { value.certificate = "" }
        if !value.certificate.isEmpty {
            guard !value.publicKey.isEmpty else { throw ResourceToolError.invalidInput }
            _ = try SSHUserCertificate.parse(
                value.certificate, matching: value.publicKey)
        }
        try Task.checkCancellation()
        guard credentials.managedKeys.first(where: { $0.id == id }) == original else {
            throw ResourceToolError.invalidInput
        }
        try credentials.saveManagedKey(value, credential: credential, passphraseUpdate: passphraseUpdate)
        guard let saved = credentials.managedKeys.first(where: { $0.id == id }) else {
            throw ResourceToolError.saveFailed
        }
        return ResourceToolOutput.key(saved)
    }
}
