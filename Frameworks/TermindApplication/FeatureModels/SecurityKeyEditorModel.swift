import Foundation
import Observation
import TermindDomain

/// Editable metadata for an existing hardware key; validation and persistence remain injected.
@MainActor
@Observable
public final class SecurityKeyEditorModel {
    public var label = ""
    public var colorTag = TagColor.none
    public var verification: SecurityKeyCredential.UserVerification = .preferred
    public private(set) var reference = ""
    public private(set) var error: String?
    public private(set) var isSaving = false
    public var canSave: Bool { originalCredential != nil && !isSaving }
    public let existing: SSHKeyRef
    public var isDirty: Bool {
        label != existing.label || colorTag != existing.colorTag
            || verification != (originalCredential?.userVerification ?? .preferred)
    }

    private var originalCredential: SecurityKeyCredential?
    private let exportReference: (SecurityKeyCredential) throws -> String
    private let validate: (SecurityKeyCredential) throws -> Void
    private let persist: (SSHKeyRef) throws -> Void

    public init(
        existing: SSHKeyRef,
        exportReference: @escaping (SecurityKeyCredential) throws -> String,
        validate: @escaping (SecurityKeyCredential) throws -> Void,
        persist: @escaping (SSHKeyRef) throws -> Void
    ) {
        self.existing = existing
        self.exportReference = exportReference
        self.validate = validate
        self.persist = persist
    }

    public func load() {
        label = existing.label
        colorTag = existing.colorTag
        do {
            guard let credential = existing.securityKey else { throw TermindSSHError.missingCredential }
            originalCredential = credential
            verification = credential.userVerification
            reference = try exportReference(credential)
        } catch { self.error = error.localizedDescription }
    }

    /// Throws so native editor containers can retain the draft and present save failures.
    public func saveChanges() async throws {
        guard !isSaving else { throw CancellationError() }
        isSaving = true
        defer { isSaving = false }
        guard var credential = originalCredential else { throw TermindSSHError.missingCredential }
        credential.userVerification = verification
        try validate(credential)
        try Task.checkCancellation()
        var key = existing
        key.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        key.colorTag = colorTag
        key.securityKey = credential
        try persist(key)
    }

    public func save() async -> Bool {
        error = nil
        do {
            try await saveChanges()
            return true
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        return false
    }
}
