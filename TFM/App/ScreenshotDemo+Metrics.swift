// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindApplication
import TermindDomain

import struct TermindDomain.Host

#if DEBUG
    import Foundation

    extension ScreenshotDemoConfiguration {
        func makeMetricsModel(hosts: HostLibraryModel) -> ServerMetricsModel {
            let rows =
                scene == .metrics || scene == .metricsDetail
                ? hosts.hosts.prefix(6).enumerated().map { metricsRow(host: $0.element, index: $0.offset) }
                : []
            return ServerMetricsModel(screenshotHosts: hosts, rows: rows)
        }

        private func metricsRow(host: Host, index: Int) -> ServerMetric {
            let gib = 1_073_741_824.0
            let mib = 1_048_576.0
            let kib = 1_024.0
            let date = Date(timeIntervalSince1970: 1_788_998_400)
            let cpu = scene == .metrics && index == 2 ? 96.4 : [32.8, 18.4, 57.2, 24.6, 8.3, 12.7][index]
            let total = [32.0, 16, 64, 8, 16, 32][index] * gib
            let memory =
                scene == .metrics
                ? [46.2, 31.7, 82.6, 22.5, 35.8, 93.1][index]
                : [46.2, 31.7, 68.4, 22.5, 35.8, 54.1][index]
            let used = total * memory / 100
            let receive =
                scene == .metrics
                ? [1.6 * mib, 96 * kib, 6.8 * mib, 0, 4.8 * kib, 64 * kib][index]
                : [8.4, 4.6, 12.8, 32.1, 1.8, 5.2][index] * mib
            let send =
                scene == .metrics
                ? [182 * kib, 24 * kib, 2.3 * mib, 0, 0, 16 * kib][index]
                : [3.2, 2.1, 4.4, 18.6, 0.6, 1.4][index] * mib
            let read =
                scene == .metrics
                ? [768 * kib, 128 * kib, 86.2 * mib, 32 * kib, 0, 0][index]
                : [12.4, 3.6, 86.2, 8.8, 1.2, 24.3][index] * mib
            let write =
                scene == .metrics
                ? [0, 0, 42.7 * mib, 12 * kib, 8 * kib, 0][index]
                : [4.8, 1.2, 42.7, 2.4, 0.8, 16.1][index] * mib
            let disk = MetricsDevicePoint(
                id: "nvme0n1", read: read, write: write, readTotal: 384 * gib, writeTotal: 128 * gib,
                readIOPS: 312, writeIOPS: 148, busy: 18.6, readWait: 0.8, writeWait: 1.2
            )
            let network = MetricsDevicePoint(
                id: "eth0", read: receive, write: send, readTotal: 186 * gib, writeTotal: 72 * gib,
                kind: .hardware, addresses: ["192.0.2.\(10 + index)"]
            )
            var point = MetricsPoint(date: date)
            point.cpu = cpu
            point.cpuUsage.system = 6.2
            point.cpuUsage.user = cpu - 6.3
            point.cpuUsage.wait = 0.3
            point.cpuUsage.steal = 0.1
            point.cpuUsage.idle = 100 - cpu - 0.3
            point.coreCount = [16, 8, 32, 4, 8, 16][index]
            point.uptime = Double(18 + index * 3) * 86_400 + 14_400
            point.load = [cpu / 10, cpu / 11, cpu / 12]
            point.memory = memory
            point.memoryUsed = used
            point.memoryTotal = total
            point.memoryCached = min(total * 0.18, (total - used) * 0.75)
            point.memoryFree = total - used - (point.memoryCached ?? 0)
            point.diskRead = read
            point.diskWrite = write
            point.networkReceive = receive
            point.networkSend = send
            point.diskDevices = [disk]
            point.blockDevices = ["259:1": disk]
            point.networkDevices = [network]
            point.networkSentTotal = network.writeTotal
            point.networkReceivedTotal = network.readTotal
            point.tcp = MetricsTCP(active: 28_640, passive: 186_412, failures: 3, retransmitted: 214, sent: 214_000)
            point.tcpRetransmissionPercent = 0.1

            let row = ServerMetric(selection: MetricsSelection(id: host.id), name: host.name)
            row.isConnecting = false
            row.status = ""
            row.point = point
            row.history = [point]
            row.disks = [disk.id]
            row.interfaces = [network.id]
            row.gpuState = .unavailable
            row.filesystems = [
                MetricsFilesystem(
                    mountPoint: "/", device: "/dev/nvme0n1p1", type: "ext4", blockID: "259:1",
                    used: 168 * gib, total: 512 * gib, usedPercent: 32.8)
            ]
            row.filesystemsDate = date
            let names = [
                "nginx", "node", "postgres", "redis-server", "containerd", "dockerd", "prometheus",
                "grafana-server", "sshd", "systemd-journald", "systemd-resolved", "cron", "node_exporter",
                "dbus-daemon", "systemd", "rsyslogd", "chronyd", "unattended-upgr", "kworker/0:1", "bash",
            ]
            row.processes = names.enumerated().map { offset, name in
                MetricsProcess(
                    pid: offset == 14 ? 1 : 1_024 + offset * 137,
                    started: UInt64(240 + offset), name: name,
                    cpu: [
                        124.8, 86.2, 48.6, 24.1, 12.4, 8.6, 6.2, 4.8, 2.1, 1.4, 0.8, 0.4, 0.3, 0.2, 0.1, 0, 0, 0, 0, 0,
                    ][
                        offset],
                    memory: Double(20 - offset) * 28 * mib)
            }
            row.processesDate = date
            return row
        }
    }
#endif
