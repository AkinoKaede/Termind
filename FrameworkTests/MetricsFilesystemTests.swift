import Foundation
import TermindDomain
import TermindInfrastructure
import Testing

@Suite
struct MetricsFilesystemTests {
    @Test
    func mountsPreserveNamesDeviceIdentityTypeAndCapacity() throws {
        let input = #"""
            24 1 259:1 / / rw - ext4 /dev/nvme0n1p1 rw
            25 1 259:2 / /srv/data\040disk rw - xfs /dev/nvme0n1p2 rw
            26 1 0:24 / /run rw - tmpfs tmpfs rw
            27 1 259:1 /var/lib/container/file /etc/hosts rw - ext4 /dev/nvme0n1p1 rw
            __TERMIND_DF__
            Filesystem Type 1024-blocks Used Available Capacity Mounted on
            /dev/nvme0n1p1 ext4 2048 1024 1024 50% /
            /dev/nvme0n1p2 xfs 4096 1024 3072 25% /srv/data disk
            tmpfs tmpfs 1000 0 1000 0% /run
            """#
        let mounts = try LinuxFilesystemParser.parse(input)
        #expect(mounts.map(\.mountPoint) == ["/", "/srv/data disk"])
        #expect(mounts.first?.device == "/dev/nvme0n1p1")
        #expect(mounts.first?.blockID == "259:1")
        #expect(mounts.first?.type == "ext4")
        #expect(mounts.first?.used == 1_048_576.0)
        #expect(mounts.first?.total == 2_097_152.0)
        #expect(mounts.last?.usedPercent == 25)
    }

    @Test
    func unknownCapacityNeverBecomesAFalseZero() throws {
        let mounts = try LinuxFilesystemParser.parse("24 1 8:1 / / rw - ext4 /dev/sda1 rw\n__TERMIND_DF__\n")
        #expect(mounts.count == 1)
        #expect(mounts.first?.used == nil && mounts.first?.usedPercent == nil)
        #expect(throws: MetricsReadError.self) { try LinuxFilesystemParser.parse("invalid") }
    }

    @Test
    func hardwareAggregationDoesNotCountVirtualTrafficTwiceAndPartitionsKeepTheirOwnIO() throws {
        let before = LinuxMetricsParser.parse(Self.sample)
        let after = LinuxMetricsParser.parse(
            Self.sample.replacingOccurrences(of: "100.0", with: "102.0")
                .replacingOccurrences(of: "1000 0 0 0 0 0 0 0 2000", with: "1200 0 0 0 0 0 0 0 2400")
                .replacingOccurrences(of: "10 0 100 20 10 0 200 30", with: "20 0 200 60 30 0 400 90")
                .replacingOccurrences(of: "Tcp: 10 20 3 100 5", with: "Tcp: 11 22 3 200 10"))
        #expect(before.interfaceKinds["ens5"] == .hardware)
        #expect(before.interfaceKinds["veth0"] == .virtual)
        #expect(before.interfaceAddresses["ens5"] == ["172.31.5.51"])
        var selection = MetricsSelection(id: UUID())
        let point = MetricsCalculation.point(previous: before, current: after, selection: selection, date: Date())
        #expect(point.networkSend == 200)
        #expect(point.networkReceive == 100)
        #expect(point.networkDevices.count == 2)
        #expect(point.networkSentTotal == 2400)
        #expect(point.tcpRetransmissionPercent == 5)
        #expect(point.tcp?.active == 11)
        let partition = try #require(point.blockDevices["259:1"])
        #expect(partition.readIOPS == 5 && partition.writeIOPS == 10)
        #expect(partition.readWait == 4 && partition.writeWait == 3)
        selection.interfaces = ["ens5", "veth0"]
        let combined = MetricsCalculation.point(previous: before, current: after, selection: selection, date: Date())
        #expect(combined.networkSend == 400)
    }

    private static let sample = """
        __TERMIND_UPTIME__
        100.0 0
        __TERMIND_NETWORK__
        ens5: 1000 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0
        veth0: 1000 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0
        __TERMIND_INTERFACES__
        ens5 hardware
        veth0 virtual
        __TERMIND_ADDRESSES__
        2: ens5 inet 172.31.5.51/24 brd 172.31.5.255 scope global ens5
        2: ens5 inet6 fe80::1/64 scope link
        __TERMIND_BLOCKS__
        259:1 nvme0n1p1 10 0 100 20 10 0 200 30 0 100 100
        __TERMIND_TCP__
        Tcp: ActiveOpens PassiveOpens AttemptFails OutSegs RetransSegs
        Tcp: 10 20 3 100 5
        """
}
