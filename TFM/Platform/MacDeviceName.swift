// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import DeviceKit
import Foundation

enum MacDeviceName {
    static var current: String {
        resolved(kernelHostname: kernelHostname(), fallback: Device.current.safeDescription)
    }

    static func resolved(kernelHostname: String?, fallback: String) -> String {
        guard let kernelHostname else { return fallback }
        let hostname = kernelHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        return hostname.isEmpty ? fallback : hostname
    }

    static func kernelHostname() -> String? {
        var size = 0
        guard sysctlbyname("kern.hostname", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.hostname", &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        let utf8 = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: utf8, as: UTF8.self)
    }
}
