import Darwin
import Foundation
import IOKit
import IOKit.serial
import TermindDomain

nonisolated final class SystemSerialPortService: SerialPortServing, @unchecked Sendable {
    private let openQueue = DispatchQueue(
        label: "com.akinokaede.termind.serial.open", attributes: .concurrent
    )
    func availablePorts() async -> [SerialPortDescriptor] { Self.scanPorts() }

    func portUpdates() -> AsyncStream<[SerialPortDescriptor]> {
        AsyncStream { continuation in
            let monitor = SerialDeviceDirectoryMonitor(continuation: continuation)
            monitor.start()
            continuation.onTermination = { _ in monitor.stop() }
        }
    }

    func open(
        _ configuration: SerialConnectionConfiguration,
        receive: @escaping @Sendable (Data) -> Void,
        disconnected: @escaping @Sendable (String) -> Void,
        progress: @escaping @Sendable (SerialPortOpenStage) -> Void
    ) async throws -> any SerialPortConnection {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<any SerialPortConnection, any Error>) in
            let attempt = SerialPortOpenAttempt(continuation: continuation)
            openQueue.async {
                do {
                    let connection = try POSIXSerialPortConnection(
                        configuration: configuration, receive: receive,
                        disconnected: disconnected, progress: progress
                    )
                    if !attempt.succeed(connection) {
                        Task { await connection.close() }
                    }
                } catch {
                    attempt.fail(error)
                }
            }
            openQueue.asyncAfter(deadline: .now() + 5) {
                attempt.fail(SerialPortError.openTimedOut)
            }
        }
    }

    fileprivate static func scanPorts() -> [SerialPortDescriptor] {
        var names: [String: String] = [:]
        if let matching = IOServiceMatching(kIOSerialBSDServiceValue) {
            var iterator: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS {
                defer { IOObjectRelease(iterator) }
                while case let service = IOIteratorNext(iterator), service != 0 {
                    defer { IOObjectRelease(service) }
                    let product =
                        property("USB Product Name", of: service)
                        ?? property("Product Name", of: service)
                        ?? property(kIOTTYBaseNameKey, of: service)
                    for key in [kIOCalloutDeviceKey, kIODialinDeviceKey] {
                        if let path = property(key, of: service) { names[path] = product }
                    }
                }
            }
        }

        // IOKit covers native macOS serial drivers. Also include likely character
        // devices so third-party drivers exposing Linux-style ttyUSB/ttyACM names
        // and user-entered development nodes are not silently hidden.
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: "/dev") {
            for entry in entries where looksLikeSerialDevice(entry) {
                let path = "/dev/\(entry)"
                var info = stat()
                if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFCHR {
                    names[path] = names[path] ?? entry
                }
            }
        }
        return SerialPortDiscovery.deduplicated(
            names.map { SerialPortDescriptor(path: $0.key, name: $0.value) }
        )
    }

    private static func property(_ key: String, of service: io_registry_entry_t) -> String? {
        IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        ) as? String
    }

    private static func looksLikeSerialDevice(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("cu.") || lower.hasPrefix("tty.")
            || lower.hasPrefix("ttyusb") || lower.hasPrefix("ttyacm")
            || lower.hasPrefix("rfcomm") || lower.hasPrefix("serial")
    }

}

nonisolated private final class SerialPortOpenAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<any SerialPortConnection, any Error>?

    init(continuation: CheckedContinuation<any SerialPortConnection, any Error>) {
        self.continuation = continuation
    }

    func succeed(_ connection: any SerialPortConnection) -> Bool {
        let continuation = takeContinuation()
        continuation?.resume(returning: connection)
        return continuation != nil
    }

    func fail(_ error: any Error) {
        takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<any SerialPortConnection, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        let result = continuation
        continuation = nil
        return result
    }
}

nonisolated enum SerialPortDiscovery {
    /// Collapses exact repeats and macOS's `cu.*`/`tty.*` aliases. Callout wins
    /// because it opens immediately; every retained row still displays its full
    /// path, including Linux-style driver nodes such as `/dev/ttyUSB0`.
    static func deduplicated(_ ports: [SerialPortDescriptor]) -> [SerialPortDescriptor] {
        var preferred: [String: SerialPortDescriptor] = [:]
        for port in ports {
            let key = deviceIdentity(port.path)
            guard let existing = preferred[key] else {
                preferred[key] = port
                continue
            }
            if priority(port.path) > priority(existing.path) { preferred[key] = port }
        }
        return preferred.values.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private static func deviceIdentity(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if name.hasPrefix("cu.") { return String(name.dropFirst(3)) }
        if name.hasPrefix("tty.") { return String(name.dropFirst(4)) }
        return name
    }

    private static func priority(_ path: String) -> Int {
        URL(fileURLWithPath: path).lastPathComponent.lowercased().hasPrefix("cu.") ? 1 : 0
    }
}

/// Watches `/dev` for actual device-node changes. This replaces periodic IOKit
/// polling: IOSerialBSDClient is enumerated once initially and only again after
/// the kernel reports an insertion, removal, rename, or attribute change.
nonisolated private final class SerialDeviceDirectoryMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.akinokaede.termind.serial.discovery")
    private let continuation: AsyncStream<[SerialPortDescriptor]>.Continuation
    private var descriptor: Int32 = -1
    private var source: (any DispatchSourceFileSystemObject)?
    private var previous: [SerialPortDescriptor] = []

    init(continuation: AsyncStream<[SerialPortDescriptor]>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        queue.async { [self] in
            publishIfChanged()
            descriptor = Darwin.open("/dev", O_EVTONLY)
            guard descriptor >= 0 else {
                continuation.finish()
                return
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .attrib],
                queue: queue
            )
            source.setEventHandler { [weak self] in self?.publishIfChanged() }
            source.setCancelHandler { [weak self] in
                guard let self, descriptor >= 0 else { return }
                Darwin.close(descriptor)
                descriptor = -1
            }
            self.source = source
            source.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
        }
    }

    private func publishIfChanged() {
        let current = SystemSerialPortService.scanPorts()
        guard current != previous else { return }
        previous = current
        continuation.yield(current)
    }
}

nonisolated private final class POSIXSerialPortConnection: SerialPortConnection,
    @unchecked Sendable
{
    private let queue = DispatchQueue(label: "com.akinokaede.termind.serial")
    private var descriptor: Int32
    private var source: (any DispatchSourceRead)!
    private var reportsDisconnect = true
    private let receive: @Sendable (Data) -> Void
    private let disconnected: @Sendable (String) -> Void

    init(
        configuration: SerialConnectionConfiguration,
        receive: @escaping @Sendable (Data) -> Void,
        disconnected: @escaping @Sendable (String) -> Void,
        progress: @escaping @Sendable (SerialPortOpenStage) -> Void
    ) throws {
        guard configuration.isValid else {
            throw SerialPortError.invalidConfiguration(
                String(localized: "Enter an absolute device path and a valid baud rate.")
            )
        }
        self.receive = receive
        self.disconnected = disconnected
        let path = configuration.normalizedDevicePath
        descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw SerialPortError.system(operation: String(localized: "Open serial port"), code: errno)
        }
        progress(.deviceOpened)
        do {
            guard ioctl(descriptor, TIOCEXCL) == 0 else {
                throw SerialPortError.system(
                    operation: String(localized: "Open serial port"), code: errno
                )
            }
            try Self.configure(descriptor, with: configuration)
            progress(.settingsApplied)
        } catch {
            Darwin.close(descriptor)
            throw error
        }

        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailableBytes() }
        source.resume()
        progress(.monitoringStarted)
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [weak self] in
                guard let self, descriptor >= 0 else {
                    continuation.resume(throwing: SerialPortError.closed)
                    return
                }
                do {
                    try data.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return }
                        var offset = 0
                        while offset < raw.count {
                            let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                            if count > 0 {
                                offset += count
                                continue
                            }
                            if count < 0, errno == EINTR { continue }
                            throw SerialPortError.system(
                                operation: String(localized: "Write serial port"), code: errno
                            )
                        }
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                self?.reportsDisconnect = false
                self?.finish(nil)
                continuation.resume()
            }
        }
    }

    private func readAvailableBytes() {
        guard descriptor >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count > 0 {
            receive(Data(bytes.prefix(count)))
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            let code = count == 0 ? ENXIO : errno
            finish(
                SerialPortError.system(
                    operation: String(localized: "Read serial port"), code: code
                ).localizedDescription)
        }
    }

    private func finish(_ message: String?) {
        guard descriptor >= 0 else { return }
        let fd = descriptor
        descriptor = -1
        source.cancel()
        Darwin.close(fd)
        if reportsDisconnect, let message { disconnected(message) }
    }

    private static func configure(
        _ descriptor: Int32, with configuration: SerialConnectionConfiguration
    ) throws {
        var options = termios()
        guard tcgetattr(descriptor, &options) == 0 else {
            throw SerialPortError.system(operation: String(localized: "Read serial settings"), code: errno)
        }
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CSIZE | PARENB | PARODD | CSTOPB | CRTSCTS)
        switch configuration.dataBits {
        case .five: options.c_cflag |= tcflag_t(CS5)
        case .six: options.c_cflag |= tcflag_t(CS6)
        case .seven: options.c_cflag |= tcflag_t(CS7)
        case .eight: options.c_cflag |= tcflag_t(CS8)
        }
        switch configuration.parity {
        case .none: break
        case .even: options.c_cflag |= tcflag_t(PARENB)
        case .odd: options.c_cflag |= tcflag_t(PARENB | PARODD)
        }
        if configuration.stopBits == .two { options.c_cflag |= tcflag_t(CSTOPB) }
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        switch configuration.flowControl {
        case .none: break
        case .software: options.c_iflag |= tcflag_t(IXON | IXOFF)
        case .hardware: options.c_cflag |= tcflag_t(CRTSCTS)
        }
        let usesStandardSpeed = [
            300, 600, 1_200, 2_400, 4_800, 9_600, 19_200, 38_400,
            57_600, 115_200, 230_400,
        ].contains(configuration.baudRate)
        let termiosSpeed = speed_t(usesStandardSpeed ? configuration.baudRate : 9_600)
        guard cfsetspeed(&options, termiosSpeed) == 0 else {
            throw SerialPortError.system(operation: String(localized: "Set baud rate"), code: errno)
        }
        guard tcsetattr(descriptor, TCSANOW, &options) == 0 else {
            throw SerialPortError.system(operation: String(localized: "Apply serial settings"), code: errno)
        }
        if !usesStandardSpeed {
            var speed = speed_t(configuration.baudRate)
            // IOSSIOSPEED is an object-like C macro and is not imported into Swift.
            // _IOW('T', 2, speed_t) on 64-bit Darwin expands to this request value.
            let setArbitrarySpeed = UInt(0x8008_5402)
            guard ioctl(descriptor, setArbitrarySpeed, &speed) == 0 else {
                throw SerialPortError.system(operation: String(localized: "Set baud rate"), code: errno)
            }
        }
    }
}
