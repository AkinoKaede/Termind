// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

@MainActor
public protocol DeviceDirectoryRepository: AnyObject {
    func devices() throws -> [DeviceRecord]
    func upsert(_ device: DeviceRecord) throws
    func registerIfNeeded(_ device: DeviceRecord) throws
}

extension DeviceDirectoryRepository {
    public func registerIfNeeded(_ device: DeviceRecord) throws { try upsert(device) }
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
