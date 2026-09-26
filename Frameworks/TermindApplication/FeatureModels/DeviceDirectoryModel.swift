import Foundation
import Observation
import TermindDomain

@MainActor
@Observable
public final class DeviceDirectoryModel {
    private let repository: any DeviceDirectoryRepository
    public let currentDeviceID: UUID
    public private(set) var currentDeviceName: String
    private var cachedDevices: [UUID: DeviceRecord] = [:]
    public private(set) var revision: UInt64 = 0
    public private(set) var storageError: String?

    public init(
        repository: (any DeviceDirectoryRepository)? = nil,
        currentDeviceID: UUID = UUID(),
        currentDeviceName: String = ProcessInfo.processInfo.hostName
    ) {
        self.repository = repository ?? InMemoryDeviceDirectoryRepository()
        self.currentDeviceID = currentDeviceID
        self.currentDeviceName = currentDeviceName
        registerCurrentDevice()
    }

    public func devices() -> [DeviceRecord] {
        _ = revision
        return Array(cachedDevices.values)
    }

    public func name(for deviceID: UUID?) -> String? {
        guard let deviceID else { return nil }
        _ = revision
        return cachedDevices[deviceID]?.displayName
            ?? (deviceID == currentDeviceID ? currentDeviceName : nil)
    }

    public func reload() {
        do {
            let values = try repository.devices()
            cachedDevices = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
            storageError = nil
        } catch {
            cachedDevices = [:]
            storageError = error.localizedDescription
        }
        revision &+= 1
    }

    public func updateCurrentDeviceName(_ name: String) {
        do {
            try repository.upsert(DeviceRecord(id: currentDeviceID, displayName: name))
            currentDeviceName = name
            reload()
        } catch {
            storageError = error.localizedDescription
        }
    }

    private func registerCurrentDevice() {
        do {
            try repository.registerIfNeeded(
                DeviceRecord(id: currentDeviceID, displayName: currentDeviceName))
        } catch {
            storageError = error.localizedDescription
        }
        // Registration can fail while previously saved device names remain readable.
        do {
            let values = try repository.devices()
            cachedDevices = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        } catch {
            storageError = error.localizedDescription
        }
    }
}
