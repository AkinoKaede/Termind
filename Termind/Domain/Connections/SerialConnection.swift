import Foundation

nonisolated struct SerialPortDescriptor: Identifiable, Hashable, Sendable {
    var path: String
    var name: String?
    var id: String { path }

    var displayName: String {
        guard let name, !name.isEmpty, name != path else { return path }
        return "\(name) — \(path)"
    }
}

nonisolated enum SerialDataBits: Int, CaseIterable, Identifiable, Sendable {
    case five = 5, six = 6, seven = 7, eight = 8
    var id: Int { rawValue }
}

nonisolated enum SerialParity: String, CaseIterable, Identifiable, Sendable {
    case none, even, odd
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: String(localized: "None")
        case .even: String(localized: "Even")
        case .odd: String(localized: "Odd")
        }
    }
}

nonisolated enum SerialStopBits: Int, CaseIterable, Identifiable, Sendable {
    case one = 1, two = 2
    var id: Int { rawValue }
}

nonisolated enum SerialFlowControl: String, CaseIterable, Identifiable, Sendable {
    case none, software, hardware
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: String(localized: "None")
        case .software: String(localized: "XON/XOFF")
        case .hardware: String(localized: "RTS/CTS")
        }
    }
}

nonisolated enum SerialEnterKey: String, CaseIterable, Identifiable, Sendable {
    case carriageReturn, lineFeed, carriageReturnLineFeed
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .carriageReturn: String(localized: "CR")
        case .lineFeed: String(localized: "LF")
        case .carriageReturnLineFeed: String(localized: "CRLF")
        }
    }
    var bytes: [UInt8] {
        switch self {
        case .carriageReturn: [0x0D]
        case .lineFeed: [0x0A]
        case .carriageReturnLineFeed: [0x0D, 0x0A]
        }
    }
}

nonisolated struct SerialConnectionConfiguration: Hashable, Sendable {
    static let commonBaudRates = [
        300, 600, 1_200, 2_400, 4_800, 9_600, 19_200, 38_400, 57_600,
        115_200, 230_400, 460_800, 921_600, 1_000_000, 2_000_000,
        3_000_000, 4_000_000,
    ]

    var devicePath = ""
    var deviceName: String?
    var baudRate = 9_600
    var dataBits: SerialDataBits = .eight
    var parity: SerialParity = .none
    var stopBits: SerialStopBits = .one
    var flowControl: SerialFlowControl = .none
    var enterKey: SerialEnterKey = .carriageReturn
    var localEcho = false

    var normalizedDevicePath: String {
        devicePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var isValid: Bool {
        normalizedDevicePath.hasPrefix("/") && (1...4_000_000).contains(baudRate)
    }
    var summary: String {
        "\(baudRate) \(dataBits.rawValue)-\(parityLetter)-\(stopBits.rawValue)"
    }
    private var parityLetter: String {
        switch parity { case .none: "N"; case .even: "E"; case .odd: "O" }
    }

    func transformInteractiveInput(_ data: Data) -> Data {
        guard enterKey != .carriageReturn, data.contains(0x0D) else { return data }
        var result = Data()
        for byte in data {
            if byte == 0x0D { result.append(contentsOf: enterKey.bytes) }
            else { result.append(byte) }
        }
        return result
    }
}
