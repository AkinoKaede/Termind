// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CloudKit
import Foundation
import Testing

@testable import TermindInfrastructure

struct CloudSyncRecordCodingTests {
    @Test(arguments: [0, 699_999, 700_000, 700_001])
    func payloadBoundaryPreservesBytesAndDefersAssetCreation(size: Int) throws {
        let record = makeRecord()
        let payload = Data(repeating: 0xAB, count: size)
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var requestedAsset = false
        func assetURL() -> URL {
            requestedAsset = true
            return url
        }

        try CloudSyncRecordCoding.setPayload(payload, on: record, assetURL: assetURL())

        #expect(requestedAsset == (size > 700_000))
        #expect((record["payloadAsset"] is CKAsset) == (size > 700_000))
        #expect((record["payload"] is Data) == (size <= 700_000))
        #expect(
            try CloudSyncRecordCoding.validatedPayloadData(from: record, invalidEnvelope: CodingError.invalidPayload)
                == payload)
    }

    @Test
    func payloadHashUsesTheExistingLowercaseSHA256WireEncoding() throws {
        let record = makeRecord()
        try CloudSyncRecordCoding.setPayload(
            Data("abc".utf8), on: record, assetURL: FileManager.default.temporaryDirectory)
        #expect(record["payloadHash"] as? String == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test
    func changingStorageRepresentationClearsThePreviousField() throws {
        let record = makeRecord()
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        record["payload"] = Data("old inline bytes".utf8) as NSData

        try CloudSyncRecordCoding.setPayload(Data(repeating: 1, count: 700_001), on: record, assetURL: url)
        #expect(record["payload"] == nil)
        #expect(record["payloadAsset"] is CKAsset)

        let inline = Data("new inline bytes".utf8)
        try CloudSyncRecordCoding.setPayload(inline, on: record, assetURL: url)
        #expect(record["payloadAsset"] == nil)
        #expect(
            try CloudSyncRecordCoding.validatedPayloadData(from: record, invalidEnvelope: CodingError.invalidPayload)
                == inline)
    }

    @Test(arguments: [nil, "incorrect"] as [String?])
    func invalidHashRejectsTheEnvelopeButKeepsRawBytesForQuarantine(hash: String?) throws {
        let record = makeRecord()
        let payload = Data("quarantined bytes".utf8)
        record["payload"] = payload as NSData
        record["payloadHash"] = hash.map { $0 as NSString }

        #expect(throws: CodingError.invalidPayload) {
            try CloudSyncRecordCoding.validatedPayloadData(from: record, invalidEnvelope: CodingError.invalidPayload)
        }
        #expect(
            try CloudSyncRecordCoding.payloadData(from: record, invalidEnvelope: CodingError.invalidPayload) == payload)
    }

    @Test
    func missingPayloadUsesTheCallersError() {
        let record = makeRecord()
        #expect(throws: CodingError.invalidPayload) {
            try CloudSyncRecordCoding.payloadData(from: record, invalidEnvelope: CodingError.invalidPayload)
        }
        #expect(throws: CodingError.invalidPayload) {
            try CloudSyncRecordCoding.validatedPayloadData(from: record, invalidEnvelope: CodingError.invalidPayload)
        }
    }

    @Test
    func inlinePayloadTakesPrecedenceAndAssetReadErrorsAreNotRemapped() throws {
        let record = makeRecord()
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("asset".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        record["payloadAsset"] = CKAsset(fileURL: url)
        try FileManager.default.removeItem(at: url)
        let inline = Data("inline".utf8)
        record["payload"] = inline as NSData
        #expect(
            try CloudSyncRecordCoding.payloadData(from: record, invalidEnvelope: CodingError.invalidPayload) == inline)

        record["payload"] = nil
        #expect(throws: CocoaError.self) {
            try CloudSyncRecordCoding.payloadData(from: record, invalidEnvelope: CodingError.invalidPayload)
        }
    }

    @Test
    func systemFieldsRestoreRecordIdentityInsteadOfUsingTheFallback() throws {
        let original = makeRecord()
        let data = try CloudSyncRecordCoding.systemFields(of: original)
        let fallback = CKRecord.ID(recordName: UUID().uuidString)
        let restored = try CloudSyncRecordCoding.makeRecord(type: "Fallback", id: fallback, systemFields: data)
        #expect(restored.recordID == original.recordID)
        #expect(restored.recordType == original.recordType)

        let fresh = try CloudSyncRecordCoding.makeRecord(type: "Fallback", id: fallback, systemFields: nil)
        #expect(fresh.recordID == fallback)
        #expect(fresh.recordType == "Fallback")
        #expect(throws: (any Error).self) {
            try CloudSyncRecordCoding.makeRecord(type: "Fallback", id: fallback, systemFields: Data([0xFF]))
        }
    }

    @Test
    func assetNamespacesDoNotOverwriteEachOtherForTheSameRecordName() throws {
        let root = "TermindTests/CloudSyncRecordCoding/\(UUID().uuidString)"
        let first = makeRecord()
        let second = CKRecord(recordType: first.recordType, recordID: first.recordID)
        let firstURL = try CloudSyncRecordCoding.assetURL(
            recordName: first.recordID.recordName, directoryName: "\(root)/first")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent().deletingLastPathComponent())
        }
        let secondURL = try CloudSyncRecordCoding.assetURL(
            recordName: second.recordID.recordName, directoryName: "\(root)/second")
        #expect(firstURL != secondURL)
        #expect(firstURL.lastPathComponent == first.recordID.recordName.replacingOccurrences(of: "/", with: "-"))
        let firstPayload = Data(repeating: 1, count: 700_001)
        let secondPayload = Data(repeating: 2, count: 700_001)
        try CloudSyncRecordCoding.setPayload(firstPayload, on: first, assetURL: firstURL)
        try CloudSyncRecordCoding.setPayload(secondPayload, on: second, assetURL: secondURL)
        #expect(
            try CloudSyncRecordCoding.validatedPayloadData(from: first, invalidEnvelope: CodingError.invalidPayload)
                == firstPayload)
        #expect(
            try CloudSyncRecordCoding.validatedPayloadData(from: second, invalidEnvelope: CodingError.invalidPayload)
                == secondPayload)
    }

    private func makeRecord() -> CKRecord {
        CKRecord(
            recordType: "CodingTestItem",
            recordID: CKRecord.ID(
                recordName: "kind/\(UUID().uuidString)",
                zoneID: CKRecordZone.ID(zoneName: "CodingTestZone", ownerName: CKCurrentUserDefaultName)))
    }

    private enum CodingError: Error, Equatable {
        case invalidPayload
    }
}
