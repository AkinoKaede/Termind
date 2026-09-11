import Foundation

public nonisolated struct SerialPortDescriptor: Identifiable, Hashable, Sendable {
    public var path: String
    public var name: String?
    public var id: String { path }

    public var displayName: String {
        guard let name, !name.isEmpty, name != path else { return path }
        return "\(name) — \(path)"
    }
    public init(path: String, name: String? = nil) {
        self.path = path
        self.name = name
    }

}

public nonisolated enum SerialDataBits: Int, CaseIterable, Identifiable, Sendable {
    case five = 5
    case six = 6
    case seven = 7
    case eight = 8
    public var id: Int { rawValue }
}

public nonisolated enum SerialParity: String, CaseIterable, Identifiable, Sendable {
    case none, even, odd
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .none: String(localized: "None")
        case .even: String(localized: "Even")
        case .odd: String(localized: "Odd")
        }
    }
}

public nonisolated enum SerialStopBits: Int, CaseIterable, Identifiable, Sendable {
    case one = 1
    case two = 2
    public var id: Int { rawValue }
}

public nonisolated enum SerialFlowControl: String, CaseIterable, Identifiable, Sendable {
    case none, software, hardware
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .none: String(localized: "None")
        case .software: String(localized: "XON/XOFF")
        case .hardware: String(localized: "RTS/CTS")
        }
    }
}

public nonisolated enum SerialEnterKey: String, CaseIterable, Identifiable, Sendable {
    case carriageReturn, lineFeed, carriageReturnLineFeed
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .carriageReturn: String(localized: "CR")
        case .lineFeed: String(localized: "LF")
        case .carriageReturnLineFeed: String(localized: "CRLF")
        }
    }
    public var bytes: [UInt8] {
        switch self {
        case .carriageReturn: [0x0D]
        case .lineFeed: [0x0A]
        case .carriageReturnLineFeed: [0x0D, 0x0A]
        }
    }
}

public nonisolated struct SerialConnectionConfiguration: Hashable, Sendable {
    public static let commonBaudRates = [
        300, 600, 1_200, 2_400, 4_800, 9_600, 19_200, 38_400, 57_600,
        115_200, 230_400, 460_800, 921_600, 1_000_000, 2_000_000,
        3_000_000, 4_000_000,
    ]

    public var devicePath = ""
    public var deviceName: String?
    public var baudRate = 9_600
    public var dataBits: SerialDataBits = .eight
    public var parity: SerialParity = .none
    public var stopBits: SerialStopBits = .one
    public var flowControl: SerialFlowControl = .none
    public var enterKey: SerialEnterKey = .carriageReturn
    public var localEcho = false

    public var normalizedDevicePath: String {
        devicePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var isValid: Bool {
        normalizedDevicePath.hasPrefix("/") && (1...4_000_000).contains(baudRate)
    }
    public var summary: String {
        "\(baudRate) \(dataBits.rawValue)-\(parityLetter)-\(stopBits.rawValue)"
    }
    private var parityLetter: String {
        switch parity {
        case .none: "N"
        case .even: "E"
        case .odd: "O"
        }
    }

    public func transformInteractiveInput(_ data: Data) -> Data {
        guard enterKey != .carriageReturn, data.contains(0x0D) else { return data }
        var result = Data()
        for byte in data {
            if byte == 0x0D { result.append(contentsOf: enterKey.bytes) } else { result.append(byte) }
        }
        return result
    }
    public init(
        devicePath: String = "", deviceName: String? = nil, baudRate: Int = 9_600, dataBits: SerialDataBits = .eight,
        parity: SerialParity = .none, stopBits: SerialStopBits = .one, flowControl: SerialFlowControl = .none,
        enterKey: SerialEnterKey = .carriageReturn, localEcho: Bool = false
    ) {
        self.devicePath = devicePath
        self.deviceName = deviceName
        self.baudRate = baudRate
        self.dataBits = dataBits
        self.parity = parity
        self.stopBits = stopBits
        self.flowControl = flowControl
        self.enterKey = enterKey
        self.localEcho = localEcho
    }

}
