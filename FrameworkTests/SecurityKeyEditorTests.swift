import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct SecurityKeyEditorTests {
    private let credential = SecurityKeyCredential(
        credentialID: Data([1, 2, 3]), publicKeyX963: Data([4, 5, 6]), userVerification: .discouraged)

    @Test func savesEditedMetadataWithoutReplacingKeyIdentityOrPublicMaterial() async {
        let existing = SSHKeyRef(
            label: "Original", algorithm: .securityKey, publicKey: "public-key", fingerprint: "fingerprint",
            storage: .thisDevice, securityKey: credential)
        var saved: SSHKeyRef?
        var validated: SecurityKeyCredential?
        let model = SecurityKeyEditorModel(
            existing: existing, exportReference: { _ in "reference" }, validate: { validated = $0 },
            persist: { saved = $0 })
        model.load()
        #expect(model.label == "Original" && model.reference == "reference")
        #expect(model.verification == .discouraged && model.canSave)
        model.label = "  Renamed  "
        model.colorTag = .purple
        model.verification = .required
        #expect(await model.save())
        var expected = existing
        expected.label = "Renamed"
        expected.colorTag = .purple
        expected.securityKey?.userVerification = .required
        #expect(saved == expected)
        #expect(validated == expected.securityKey)
        #expect(model.error == nil && !model.isSaving)
    }

    @Test func validationAndPersistenceFailuresKeepTheEditorOpen() async {
        var persisted = false
        let existing = SSHKeyRef(label: "Key", securityKey: credential)
        let rejected = SecurityKeyEditorModel(
            existing: existing, exportReference: { _ in "reference" }, validate: { _ in throw EditFailure() },
            persist: { _ in persisted = true })
        rejected.load()
        #expect(!(await rejected.save()))
        #expect(!persisted && rejected.error == "Fixture edit failure")
        #expect(rejected.canSave)
        let failed = SecurityKeyEditorModel(
            existing: existing, exportReference: { _ in "reference" }, validate: { _ in },
            persist: { _ in throw EditFailure() })
        failed.load()
        #expect(!(await failed.save()))
        #expect(failed.error == "Fixture edit failure" && failed.canSave)
    }

    @Test func cancellationBeforeSaveDoesNotPersistOrReportAnError() async {
        var persisted = false
        let model = SecurityKeyEditorModel(
            existing: SSHKeyRef(label: "Key", securityKey: credential), exportReference: { _ in "reference" },
            validate: { _ in }, persist: { _ in persisted = true })
        model.load()
        let task = Task { await model.save() }
        task.cancel()
        #expect(!(await task.value))
        #expect(!persisted && model.error == nil && !model.isSaving)
    }

    @Test func missingCredentialCannotBeSaved() async {
        var persisted = false
        let model = SecurityKeyEditorModel(
            existing: SSHKeyRef(label: "Missing"), exportReference: { _ in "reference" }, validate: { _ in },
            persist: { _ in persisted = true })
        model.load()
        #expect(!model.canSave && model.error != nil)
        #expect(!(await model.save()))
        #expect(!persisted)
    }

    @Test func dirtyStateTracksEachEditableFieldAndRevertingChanges() {
        let existing = SSHKeyRef(label: "Key", securityKey: credential)
        let model = SecurityKeyEditorModel(
            existing: existing, exportReference: { _ in "reference" }, validate: { _ in }, persist: { _ in })
        model.load()
        #expect(!model.isDirty)
        model.label = "Renamed"
        #expect(model.isDirty)
        model.label = existing.label
        #expect(!model.isDirty)
        model.colorTag = .purple
        #expect(model.isDirty)
        model.colorTag = existing.colorTag
        #expect(!model.isDirty)
        model.verification = .required
        #expect(model.isDirty)
        model.verification = credential.userVerification
        #expect(!model.isDirty)
    }

    @Test func nativeEditorReceivesSaveFailuresAndCanRetryTheSameDraft() async throws {
        var shouldFail = true
        var persisted: SSHKeyRef?
        let model = SecurityKeyEditorModel(
            existing: SSHKeyRef(label: "Key", securityKey: credential),
            exportReference: { _ in "reference" }, validate: { _ in },
            persist: {
                if shouldFail { throw EditFailure() }
                persisted = $0
            })
        model.load()
        model.label = "Renamed"
        await #expect(throws: EditFailure.self) { try await model.saveChanges() }
        #expect(persisted == nil && model.isDirty && model.canSave)
        #expect(model.label == "Renamed")
        shouldFail = false
        try await model.saveChanges()
        #expect(persisted?.label == "Renamed")
    }

    private struct EditFailure: LocalizedError {
        var errorDescription: String? { "Fixture edit failure" }
    }
}
