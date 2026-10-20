// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindDomain

/// Validated transient input. Never put this value in a configuration snapshot or sync payload.
public nonisolated struct ModelProviderServiceAccount: Sendable {
    public static let maximumBytes = 1_048_576
    public let json: String
    public let clientEmail: String
    public let projectID: String

    public init(json: String) throws {
        guard json.utf8.count <= Self.maximumBytes,
            let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            object["type"] as? String == "service_account",
            let tokenURI = object["token_uri"] as? String,
            ["https://oauth2.googleapis.com/token", "https://accounts.google.com/o/oauth2/token"].contains(tokenURI),
            let key = object["private_key"] as? String,
            key.hasPrefix("-----BEGIN PRIVATE KEY-----"),
            key.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("-----END PRIVATE KEY-----"),
            let der = Data(
                base64Encoded: key.replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
                    .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
                    .components(separatedBy: .whitespacesAndNewlines).joined()),
            der.count > 256, der.first == 0x30,
            let email = GoogleServiceAccountAuth.clientEmail(in: json), email.contains("@"),
            let project = GoogleServiceAccountAuth.projectID(in: json), !project.isEmpty
        else { throw ValidationError.invalid }
        self.json = json
        clientEmail = email
        projectID = project
    }

    public enum ValidationError: LocalizedError {
        case invalid
        public var errorDescription: String? {
            String(localized: "Choose a valid Google service account JSON file smaller than 1 MiB.")
        }
    }
}

public nonisolated enum ModelProviderCredentialKind: Sendable {
    case apiKey, serviceAccount

    public func reference(in provider: ModelProvider) -> String {
        switch self {
        case .apiKey: provider.credentialRef
        case .serviceAccount: provider.vertex.credentialRef
        }
    }

    public func setReference(_ reference: String, in provider: inout ModelProvider) {
        switch self {
        case .apiKey: provider.credentialRef = reference
        case .serviceAccount: provider.vertex.credentialRef = reference
        }
    }
}

/// A compare-and-swap edit held only for the duration of an editor transaction.
public nonisolated struct ModelProviderCredentialEdit {
    public let kind: ModelProviderCredentialKind
    public let reference: String
    public let previous: String?
    public let replacement: String?

    public init(kind: ModelProviderCredentialKind, reference: String, previous: String?, replacement: String?) {
        self.kind = kind
        self.reference = reference
        self.previous = previous
        self.replacement = replacement
    }
}

extension AIConfigurationModel {
    /// Writes both secrets before metadata, rolling every changed secret back if any step fails.
    public func saveProvider(
        _ draft: ModelProvider, endpoint: ProviderEndpoint, credentials: [ModelProviderCredentialEdit]
    ) throws {
        var value = draft
        let current = modelProvider(draft.id)
        for edit in credentials {
            guard edit.kind.reference(in: current ?? draft) == edit.reference else {
                throw SettingsDraftMerge.Conflict.changed
            }
            let previous = secret(for: edit.reference)
            if let error = secretStorageError, !edit.reference.isEmpty { throw CredentialError.message(error) }
            guard previous == edit.previous else { throw SettingsDraftMerge.Conflict.changed }
        }
        var rollback: [(String, String?)] = []
        do {
            for edit in credentials {
                if edit.reference.isEmpty && edit.replacement == nil { continue }
                let reference = edit.reference.isEmpty ? Self.makeCredentialRef("provider") : edit.reference
                rollback.append((reference, edit.previous))
                setSecret(edit.replacement, for: reference)
                if let error = secretStorageError { throw CredentialError.message(error) }
                edit.kind.setReference(edit.replacement == nil ? "" : reference, in: &value)
            }
            guard saveProvider(value, endpoint: endpoint) else {
                throw CredentialError.message(storageError ?? String(localized: "Unable to Save"))
            }
        } catch {
            var message = error.localizedDescription
            for (reference, previous) in rollback.reversed() {
                setSecret(previous, for: reference)
                if let failure = secretStorageError { message += "\n" + failure }
            }
            throw CredentialError.message(message)
        }
    }

    public enum CredentialError: LocalizedError {
        case message(String)
        public var errorDescription: String? {
            switch self {
            case .message(let message): message
            }
        }
    }
}
