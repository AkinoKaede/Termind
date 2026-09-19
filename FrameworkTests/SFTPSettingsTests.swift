import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct SFTPSettingsTests {
    @Test func defaultsAndRangesHaveOneSharedDefinition() {
        #expect(SFTPPreferences() == SFTPPreferences(globalLimit: 30, perHostLimit: 10, strategy: .smart))
        #expect(SettingsKey.defaultSFTPGlobalTransferLimit == 30)
        #expect(SettingsKey.defaultSFTPPerHostTransferLimit == 10)
        #expect(SettingsKey.sftpGlobalTransferLimitRange == 1...100)
        #expect(SettingsKey.sftpPerHostTransferLimitRange == 1...50)
    }

    @Test(arguments: [(0, 0, 1, 1), (200, 80, 100, 50), (3, 7, 3, 3), (100, 50, 100, 50), (3, 2, 3, 2)])
    func normalizationEnforcesBothLimits(_ input: (Int, Int, Int, Int)) {
        let value = SFTPPreferences(globalLimit: input.0, perHostLimit: input.1)
        #expect(value.globalLimit == input.2)
        #expect(value.perHostLimit == input.3)
        #expect(value.isValid)
        #expect(value.availablePerHostRange.upperBound == min(50, input.2))
    }

    @Test func failedSavePreservesPreferencesAndDoesNotNotifyTheRuntime() {
        let persistence = TestSFTPPreferencesPersistence()
        let model = SFTPSettingsModel(persistence: persistence)
        var received: [SFTPPreferences] = []
        model.didChange = { received.append($0) }
        persistence.fail = true
        #expect(!model.set(100, for: \.globalLimit))
        #expect(model.preferences == SFTPPreferences())
        #expect(persistence.value == SFTPPreferences())
        #expect(model.storageError != nil)
        #expect(received.isEmpty)

        persistence.fail = false
        #expect(model.set(100, for: \.globalLimit))
        #expect(model.storageError == nil)
        #expect(received == [SFTPPreferences(globalLimit: 100, perHostLimit: 10)])
    }

    @Test func remoteChangesNotifyOnceWithoutSavingAndLocalChangesCommitThePair() {
        let persistence = TestSFTPPreferencesPersistence()
        let model = SFTPSettingsModel(persistence: persistence)
        var received: [SFTPPreferences] = []
        model.didChange = { received.append($0) }
        let remote = SFTPPreferences(globalLimit: 100, perHostLimit: 50)
        model.applyRemoteSnapshot(remote)
        model.applyRemoteSnapshot(remote)
        #expect(received == [remote])
        #expect(persistence.saves == 0)
        #expect(model.set(3, for: \.globalLimit))
        #expect(persistence.value == SFTPPreferences(globalLimit: 3, perHostLimit: 3))
        #expect(persistence.saves == 1)
        #expect(received.last == persistence.value)
    }

    @Test func strategyPersistsAndOlderJSONDefaultsToSmart() throws {
        let legacy = try JSONDecoder().decode(
            SFTPPreferences.self,
            from: Data(#"{"globalLimit":15,"perHostLimit":5}"#.utf8))
        #expect(legacy == SFTPPreferences(globalLimit: 15, perHostLimit: 5, strategy: .smart))

        let persistence = TestSFTPPreferencesPersistence()
        let model = SFTPSettingsModel(persistence: persistence)
        #expect(model.setStrategy(.channelsOnly))
        #expect(persistence.value.strategy == .channelsOnly)
        #expect(persistence.saves == 1)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                SFTPPreferences.self,
                from: Data(#"{"globalLimit":30,"perHostLimit":10,"strategy":"future"}"#.utf8))
        }
    }
}

@MainActor
private final class TestSFTPPreferencesPersistence: SFTPPreferencesPersisting {
    var value = SFTPPreferences()
    var saves = 0
    var fail = false

    func loadSFTP() throws -> SFTPPreferences { value }
    func saveSFTP(_ value: SFTPPreferences) throws {
        if fail { throw CocoaError(.fileWriteNoPermission) }
        self.value = value
        saves += 1
    }
}
