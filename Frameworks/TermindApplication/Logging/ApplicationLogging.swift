// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Logging

public nonisolated enum ApplicationLogLevel: String, CaseIterable, Identifiable, Sendable {
    case error
    case warning
    case info
    case debug
    case trace

    public var id: String { rawValue }

    public var loggerLevel: Logger.Level {
        switch self {
        case .error: .error
        case .warning: .warning
        case .info: .info
        case .debug: .debug
        case .trace: .trace
        }
    }

    public var localizedName: String {
        switch self {
        case .error: String(localized: "Error")
        case .warning: String(localized: "Warning")
        case .info: String(localized: "Info")
        case .debug: String(localized: "Debug")
        case .trace: String(localized: "Trace")
        }
    }

    public init(loggerLevel: Logger.Level) {
        switch loggerLevel {
        case .trace: self = .trace
        case .debug: self = .debug
        case .info, .notice: self = .info
        case .warning: self = .warning
        case .error, .critical: self = .error
        }
    }
}

public nonisolated struct ApplicationLogFile: Identifiable, Hashable, Sendable {
    public let id: String
    public let createdAt: Date
    public let byteCount: Int64
    public let isCurrent: Bool

    public init(id: String, createdAt: Date, byteCount: Int64, isCurrent: Bool) {
        self.id = id
        self.createdAt = createdAt
        self.byteCount = byteCount
        self.isCurrent = isCurrent
    }
}

public nonisolated protocol ApplicationLogManaging: AnyObject, Sendable {
    var isSaving: Bool { get }

    func makeLogger(label: String) -> Logger
    func setSaving(_ enabled: Bool) throws
    func setLevel(_ level: ApplicationLogLevel)
    func files() throws -> [ApplicationLogFile]
    func exportURL(for id: ApplicationLogFile.ID) throws -> URL
    func delete(_ id: ApplicationLogFile.ID) throws
    func deleteAll() throws
}

public nonisolated enum ApplicationLogger {
    public static func disabled(_ label: String) -> Logger {
        Logger(label: label) { _ in SwiftLogNoOpLogHandler() }
    }
}

public nonisolated final class DisabledApplicationLogManager: ApplicationLogManaging, @unchecked Sendable {
    public static let shared = DisabledApplicationLogManager()

    public var isSaving: Bool { false }

    private init() {}

    public func makeLogger(label: String) -> Logger { ApplicationLogger.disabled(label) }
    public func setSaving(_: Bool) throws {}
    public func setLevel(_: ApplicationLogLevel) {}
    public func files() throws -> [ApplicationLogFile] { [] }
    public func exportURL(for _: ApplicationLogFile.ID) throws -> URL { throw CocoaError(.fileNoSuchFile) }
    public func delete(_: ApplicationLogFile.ID) throws {}
    public func deleteAll() throws {}
}
