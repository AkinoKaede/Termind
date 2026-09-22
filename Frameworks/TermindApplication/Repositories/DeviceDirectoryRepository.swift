import Foundation
import TermindDomain

@MainActor
public protocol DeviceDirectoryRepository: AnyObject {
    func devices() throws -> [DeviceRecord]
    func upsert(_ device: DeviceRecord) throws
}

@MainActor
public final class InMemoryDeviceDirectoryRepository: DeviceDirectoryRepository {
    private var values: [UUID: DeviceRecord]

    public init(devices: [DeviceRecord] = []) {
        values = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
    }

    public func devices() throws -> [DeviceRecord] { Array(values.values) }

    public func upsert(_ device: DeviceRecord) throws { values[device.id] = device }
}
