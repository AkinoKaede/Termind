import Foundation
import TermindDomain

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
        case .closed: String(localized: "The serial port is closed.")
        case .openTimedOut: String(localized: "Opening the serial port timed out.")
        }
    }
}

nonisolated enum SerialPortOpenStage: Sendable {
    case deviceOpened
    case settingsApplied
    case monitoringStarted

    var message: String {
        switch self {
        case .deviceOpened: String(localized: "Serial device opened")
        case .settingsApplied: String(localized: "Serial settings applied")
        case .monitoringStarted: String(localized: "Serial input monitoring started")
        }
    }
}

protocol SerialPortConnection: Sendable {
    func write(_ data: Data) async throws
    func close() async
}

protocol SerialPortServing: Sendable {
    func availablePorts() async -> [SerialPortDescriptor]
    func portUpdates() -> AsyncStream<[SerialPortDescriptor]>
    func open(
        _ configuration: SerialConnectionConfiguration,
        receive: @escaping @Sendable (Data) -> Void,
        disconnected: @escaping @Sendable (String) -> Void,
        progress: @escaping @Sendable (SerialPortOpenStage) -> Void
    ) async throws -> any SerialPortConnection
}
