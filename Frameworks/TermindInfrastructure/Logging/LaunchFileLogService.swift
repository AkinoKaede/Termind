import Foundation
import Logging
import TermindApplication

public nonisolated enum LaunchFileLogError: LocalizedError, Sendable {
    case invalidFile
    case missingFile

    public var errorDescription: String? {
        switch self {
        case .invalidFile: String(localized: "The selected logging file is invalid.")
        case .missingFile: String(localized: "The selected logging file no longer exists.")
        }
    }
}

/// A process-wide SwiftLog backend that writes every label into one file for the current launch.
/// The file is created lazily and only while saving is enabled.
public nonisolated final class LaunchFileLogService: ApplicationLogManaging, @unchecked Sendable {
    private let core: LaunchFileLogCore

    public init(
        directory: URL? = nil,
        defaults: UserDefaults = .standard,
        launchDate: Date = .now,
        launchID: UUID = UUID()
    ) {
        let baseDirectory =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logging", isDirectory: true)
        core = LaunchFileLogCore(
            directory: baseDirectory,
            defaults: defaults,
            launchDate: launchDate,
            launchID: launchID
        )
    }

    public var isSaving: Bool { core.isSaving }
    public var level: ApplicationLogLevel { core.level }

    public func makeLogger(label: String) -> Logger {
        Logger(label: label) { [core] label in
            LaunchFileLogHandler(label: label, core: core)
        }
    }

    public func setSaving(_ enabled: Bool) throws { try core.setSaving(enabled) }
    public func setLevel(_ level: ApplicationLogLevel) { core.setLevel(level) }
    public func files() throws -> [ApplicationLogFile] { try core.files() }
    public func exportURL(for id: ApplicationLogFile.ID) throws -> URL { try core.exportURL(for: id) }
    public func delete(_ id: ApplicationLogFile.ID) throws { try core.delete(id) }
    public func deleteAll() throws { try core.deleteAll() }
}

private nonisolated struct LaunchFileLogHandler: LogHandler {
    let label: String
    let core: LaunchFileLogCore
    var metadataProvider: Logger.MetadataProvider?
    var metadata: Logger.Metadata = [:]

    init(label: String, core: LaunchFileLogCore) {
        self.label = label
        self.core = core
    }

    var logLevel: Logger.Level {
        get { core.loggerLevel }
        set { core.setLevel(ApplicationLogLevel(loggerLevel: newValue)) }
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        var combined = metadata
        if let provided = metadataProvider?.get() {
            combined.merge(provided) { _, provided in provided }
        }
        if let explicit = event.metadata {
            combined.merge(explicit) { _, explicit in explicit }
        }
        core.emit(label: label, event: event, metadata: combined)
    }
}

private nonisolated final class LaunchFileLogCore: @unchecked Sendable {
    private static let metricsPayloadKey = "metrics_payload"
    private static let metricsPayloadEvents: Set<String> = [
        "metrics.sample.incomplete", "metrics.sample.oversized",
    ]
    private static let maximumMetricsPayloadBytes = 8 * 1_024

    private let lock = NSLock()
    private let directory: URL
    private let defaults: UserDefaults
    private let currentID: String
    private let launchDate: Date
    private let timestampFormatter: ISO8601DateFormatter
    private var saving: Bool
    private var configuredLevel: ApplicationLogLevel
    private var writer: FileHandle?

    init(directory: URL, defaults: UserDefaults, launchDate: Date, launchID: UUID) {
        self.directory = directory
        self.defaults = defaults
        self.launchDate = launchDate
        saving = defaults.object(forKey: SettingsKey.loggingSavingEnabled) as? Bool ?? false
        configuredLevel =
            defaults.string(forKey: SettingsKey.loggingLevel).flatMap(ApplicationLogLevel.init(rawValue:)) ?? .info

        let filenameFormatter = DateFormatter()
        filenameFormatter.calendar = Calendar(identifier: .iso8601)
        filenameFormatter.locale = Locale(identifier: "en_US_POSIX")
        filenameFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        filenameFormatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        currentID = "termind-\(filenameFormatter.string(from: launchDate))-\(launchID.uuidString.lowercased()).log"

        timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    deinit { try? writer?.close() }

    var isSaving: Bool { lock.withLock { saving } }
    var level: ApplicationLogLevel { lock.withLock { configuredLevel } }
    var loggerLevel: Logger.Level { level.loggerLevel }

    func setSaving(_ enabled: Bool) throws {
        try lock.withLock {
            guard saving != enabled else { return }
            if enabled {
                try openWriterLocked()
                saving = true
            } else {
                saving = false
                try closeWriterLocked()
            }
            defaults.set(enabled, forKey: SettingsKey.loggingSavingEnabled)
        }
    }

    func setLevel(_ level: ApplicationLogLevel) {
        lock.withLock { configuredLevel = level }
        defaults.set(level.rawValue, forKey: SettingsKey.loggingLevel)
    }

    func emit(label: String, event: LogEvent, metadata: Logger.Metadata) {
        let data: Data? = lock.withLock {
            guard event.level >= configuredLevel.loggerLevel else { return nil }
            let line = formattedLineLocked(label: label, event: event, metadata: metadata)
            guard let data = line.data(using: .utf8) else { return nil }
            if saving {
                do {
                    try openWriterLocked()
                    try writer?.write(contentsOf: data)
                } catch {
                    try? closeWriterLocked()
                }
            }
            return data
        }
        #if DEBUG
            if let data { try? FileHandle.standardError.write(contentsOf: data) }
        #endif
    }

    func files() throws -> [ApplicationLogFile] {
        try lock.withLock {
            try synchronizeLocked()
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ).compactMap { url in
                guard url.pathExtension == "log", Self.isValidID(url.lastPathComponent) else { return nil }
                let values = try url.resourceValues(forKeys: keys)
                return ApplicationLogFile(
                    id: url.lastPathComponent,
                    createdAt: values.creationDate ?? values.contentModificationDate ?? .distantPast,
                    byteCount: Int64(values.fileSize ?? 0),
                    isCurrent: url.lastPathComponent == currentID
                )
            }.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id > $1.id
            }
        }
    }

    func exportURL(for id: ApplicationLogFile.ID) throws -> URL {
        try lock.withLock {
            let url = try fileURLLocked(for: id)
            try synchronizeLocked()
            guard FileManager.default.fileExists(atPath: url.path) else { throw LaunchFileLogError.missingFile }
            return url
        }
    }

    func delete(_ id: ApplicationLogFile.ID) throws {
        try lock.withLock {
            let url = try fileURLLocked(for: id)
            if id == currentID { try closeWriterLocked() }
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            if id == currentID, saving { try openWriterLocked() }
        }
    }

    func deleteAll() throws {
        try lock.withLock {
            try closeWriterLocked()
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            if saving { try openWriterLocked() }
        }
    }

    private func fileURLLocked(for id: String) throws -> URL {
        guard Self.isValidID(id) else { throw LaunchFileLogError.invalidFile }
        return directory.appendingPathComponent(id, isDirectory: false)
    }

    private func openWriterLocked() throws {
        guard writer == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(currentID, isDirectory: false)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.setAttributes([.creationDate: launchDate], ofItemAtPath: url.path)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        writer = handle
    }

    private func synchronizeLocked() throws { try writer?.synchronize() }

    private func closeWriterLocked() throws {
        guard let writer else { return }
        self.writer = nil
        try writer.synchronize()
        try writer.close()
    }

    private func formattedLineLocked(label: String, event: LogEvent, metadata: Logger.Metadata) -> String {
        let timestamp = timestampFormatter.string(from: .now)
        let safeLabel = Self.safeToken(label, fallback: "termind")
        let safeEvent = Self.safeToken(event.message.description, fallback: "event.redacted")
        var fields = metadata.keys.sorted().compactMap { key -> String? in
            guard key != Self.metricsPayloadKey, Self.safeToken(key, fallback: "") == key,
                let value = metadata[key]
            else { return nil }
            return "\(key)=\(Self.safeToken(value.description, fallback: "redacted"))"
        }
        if Self.metricsPayloadEvents.contains(event.message.description),
            let payload = metadata[Self.metricsPayloadKey]
        {
            let (escaped, truncated) = Self.escapedMetricsPayload(payload.description)
            fields.append("metrics_payload=\"\(escaped)\"")
            if truncated, metadata["metrics_payload_truncated"] == nil {
                fields.append("metrics_payload_truncated=true")
            }
        }
        let suffix = fields.isEmpty ? "" : " " + fields.joined(separator: " ")
        return "\(timestamp) \(event.level.rawValue.uppercased()) \(safeLabel) \(safeEvent)\(suffix)\n"
    }

    private static func isValidID(_ id: String) -> Bool {
        id == URL(fileURLWithPath: id).lastPathComponent && !id.contains("/") && id.hasSuffix(".log")
    }

    private static func safeToken(_ value: String, fallback: String) -> String {
        guard !value.isEmpty, value.utf8.count <= 96,
            value.unicodeScalars.allSatisfy({ scalar in
                switch scalar.value {
                case 45, 46, 48...57, 65...90, 95, 97...122: true
                default: false
                }
            })
        else { return fallback }
        return value
    }

    private static func escapedMetricsPayload(_ value: String) -> (String, Bool) {
        let bytes = Array(value.utf8)
        let truncated = bytes.count > maximumMetricsPayloadBytes
        let text = String(decoding: bytes.prefix(maximumMetricsPayloadBytes), as: UTF8.self)
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: escaped += "\\\""
            case 0x5C: escaped += "\\\\"
            case 0x0A: escaped += "\\n"
            case 0x0D: escaped += "\\r"
            case 0x09: escaped += "\\t"
            case 0x00...0x1F, 0x7F: escaped += String(format: "\\u{%02X}", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return (escaped, truncated)
    }
}
