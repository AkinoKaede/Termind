// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain
import TermindPresentation

nonisolated enum SerialPortError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case system(operation: String, code: Int32)
    case closed
    case openTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .system(let operation, let code):
            "\(operation): \(String(cString: strerror(code)))"
        case .closed: String(localized: AppStrings.Terminal.theSerialPortIsClosed)
        case .openTimedOut: String(localized: AppStrings.Terminal.openingTheSerialPortTimedOut)
        }
    }
}

nonisolated enum SerialPortOpenStage: Sendable {
    case deviceOpened
    case settingsApplied
    case monitoringStarted

    var message: String {
        switch self {
        case .deviceOpened: String(localized: AppStrings.Terminal.serialDeviceOpened)
        case .settingsApplied: String(localized: AppStrings.Terminal.serialSettingsApplied)
        case .monitoringStarted: String(localized: AppStrings.Terminal.serialInputMonitoringStarted)
        }
    }
}

protocol SerialPortConnection: Sendable {
    func write(_ data: Data) async throws
    func close() async
}

protocol SerialPortServing: Sendable {
    func portUpdates() -> AsyncStream<[SerialPortDescriptor]>
    func open(
        _ configuration: SerialConnectionConfiguration,
        receive: @escaping @Sendable (Data) -> Void,
        disconnected: @escaping @Sendable (String) -> Void,
        progress: @escaping @Sendable (SerialPortOpenStage) -> Void
    ) async throws -> any SerialPortConnection
}
