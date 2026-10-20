// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation
import TermindApplication
import TermindDomain

nonisolated struct LocalIPv4Interface: Hashable, Sendable {
    var address: UInt32
    var mask: UInt32
    var index: UInt32 = 0

    var broadcast: UInt32 { (address & mask) | ~mask }
    var scanAddresses: [String] {
        let scanMask = mask | 0xFFFF_FF00
        let first = address & scanMask
        let last = first | ~scanMask
        guard last - first > 1 else { return [] }
        return ((first + 1)..<last).filter { $0 != address }.map(Self.string)
    }

    static func string(_ address: UInt32) -> String {
        [24, 16, 8, 0].map { String((address >> $0) & 255) }.joined(separator: ".")
    }

    static var hasPhysicalNetwork: Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let item = entry.pointee
            let flags = Int32(item.ifa_flags)
            if String(cString: item.ifa_name).hasPrefix("en"),
                flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                let address = item.ifa_addr,
                address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6
            {
                return true
            }
        }
        return false
    }

    static func current() -> [Self] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(first) }
        var result: Set<Self> = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let item = entry.pointee
            let flags = Int32(item.ifa_flags)
            // Darwin's physical Ethernet/Wi-Fi adapters use en*. Never sweep tunnels or cellular.
            guard String(cString: item.ifa_name).hasPrefix("en"),
                flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_BROADCAST != 0,
                flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                let address = item.ifa_addr, address.pointee.sa_family == AF_INET,
                let mask = item.ifa_netmask
            else { continue }
            let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            let netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            result.insert(
                .init(
                    address: UInt32(bigEndian: ip), mask: UInt32(bigEndian: netmask),
                    index: if_nametoindex(item.ifa_name)))
        }
        return result.sorted { $0.address < $1.address }
    }
}

public nonisolated struct LANWakeOnLANSender: WakeOnLANSending {
    public init() {}

    public func send(to address: MACAddress) throws {
        let interfaces = LocalIPv4Interface.current().filter { $0.mask < 0xFFFF_FFFE }
        guard !interfaces.isEmpty else { throw WakeOnLANError.noLocalNetwork }
        var sent = false
        var failure: Int32 = 0
        for interface in interfaces {
            try Task.checkCancellation()
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else {
                failure = errno
                continue
            }
            defer { close(fd) }
            var enabled: Int32 = 1
            var index = interface.index
            guard
                fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
                setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0,
                setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout.size(ofValue: index))) == 0
            else {
                failure = errno
                continue
            }
            var local = sockaddr_in()
            local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            local.sin_family = sa_family_t(AF_INET)
            local.sin_addr.s_addr = interface.address.bigEndian
            let bound = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else {
                failure = errno
                continue
            }
            var target = local
            target.sin_port = UInt16(9).bigEndian
            target.sin_addr.s_addr = interface.broadcast.bigEndian
            let packet = address.magicPacket
            let count = packet.withUnsafeBytes { bytes in
                withUnsafePointer(to: &target) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if count == packet.count { sent = true } else { failure = errno }
        }
        guard sent else { throw WakeOnLANError.sendFailed(failure) }
    }
}
