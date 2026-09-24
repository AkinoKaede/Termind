import CloudKit
import CryptoKit
import Foundation

/// CloudKit transport mechanics shared by the independently owned sync coordinators.
nonisolated enum CloudSyncRecordCoding {
    static let inlinePayloadLimit = 700_000

    static func makeRecord(type: String, id: CKRecord.ID, systemFields: Data?) throws -> CKRecord {
        if let systemFields {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: systemFields)
            unarchiver.requiresSecureCoding = true
            defer { unarchiver.finishDecoding() }
            if let restored = CKRecord(coder: unarchiver) { return restored }
        }
        return CKRecord(recordType: type, recordID: id)
    }

    static func setPayload(
        _ payload: Data, on record: CKRecord, assetURL: @autoclosure () throws -> URL
    ) throws {
        record["payloadHash"] = hash(payload) as NSString
        if payload.count > inlinePayloadLimit {
            let url = try assetURL()
            try payload.write(to: url, options: .atomic)
            record["payload"] = nil
            record["payloadAsset"] = CKAsset(fileURL: url)
        } else {
            record["payload"] = payload as NSData
            record["payloadAsset"] = nil
        }
    }

    static func validatedPayloadData(
        from record: CKRecord, invalidEnvelope: @autoclosure () -> any Error
    ) throws -> Data {
        let data = try payloadData(from: record, invalidEnvelope: invalidEnvelope())
        guard record["payloadHash"] as? String == hash(data) else { throw invalidEnvelope() }
        return data
    }

    /// Raw bytes remain available to quarantine even when the payload hash is invalid.
    static func payloadData(
        from record: CKRecord, invalidEnvelope: @autoclosure () -> any Error
    ) throws -> Data {
        if let inline = record["payload"] as? Data { return inline }
        if let asset = record["payloadAsset"] as? CKAsset, let url = asset.fileURL {
            return try Data(contentsOf: url)
        }
        throw invalidEnvelope()
    }

    static func systemFields(of record: CKRecord) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    static func assetURL(
        recordName: String, directoryName: String, cacheRoot: URL? = nil
    ) throws -> URL {
        let directory = try assetDirectory(directoryName: directoryName, cacheRoot: cacheRoot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: recordName.replacingOccurrences(of: "/", with: "-"))
    }

    static func purgeAssetDirectory(
        directoryName: String, cacheRoot: URL? = nil,
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws {
        let directory = try assetDirectory(directoryName: directoryName, cacheRoot: cacheRoot)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try removeItem(directory)
    }

    private static func assetDirectory(directoryName: String, cacheRoot: URL?) throws -> URL {
        let root = (cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
            .standardizedFileURL
        let directory = root.appending(path: directoryName, directoryHint: .isDirectory).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard directory.path.hasPrefix(prefix), directory != root else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return directory
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
