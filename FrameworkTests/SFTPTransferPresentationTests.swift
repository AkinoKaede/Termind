// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain
import TermindPresentation
import Testing

import struct TermindDomain.Host

@Suite("SFTP transfer presentation")
struct SFTPTransferPresentationTests {
    @Test
    func uploadAndDownloadRoutesHideLocalPathsAndAbbreviateHomeInEveryState() {
        let source = Host(name: "Source", host: "source.example")
        let destination = Host(name: "Destination", host: "destination.example")
        let names = [source.id: source.name, destination.id: destination.name]
        let states: [SFTPTransfer.State] = [
            .queued, .running, .paused, .completed, .cancelled, .failed("Offline"),
        ]

        for state in states {
            let upload = SFTPTransfer(
                sourceHostID: nil,
                destinationHostID: destination.id,
                direction: .upload,
                localPath: "/Users/example/private/upload.txt",
                remotePath: "/home/deploy/releases/upload.txt",
                destinationHomeDirectory: "/home/deploy",
                state: state
            )
            let download = SFTPTransfer(
                sourceHostID: source.id,
                destinationHostID: nil,
                direction: .download,
                localPath: "/Users/example/private/download.txt",
                remotePath: "/home/deploy/backups/download.txt",
                sourceHomeDirectory: "/home/deploy",
                state: state
            )

            let uploadRoute = upload.routeLabel { names[$0] }
            let downloadRoute = download.routeLabel { names[$0] }

            #expect(uploadRoute == "Destination · ~/releases/upload.txt")
            #expect(downloadRoute == "Source · ~/backups/download.txt")
            #expect(!uploadRoute.contains(upload.localPath))
            #expect(!downloadRoute.contains(download.localPath))
        }
    }

    @Test
    func remoteCopyRoutesStillShowBothRemoteEndpoints() {
        let source = Host(name: "Source", host: "source.example")
        let destination = Host(name: "Destination", host: "destination.example")
        let names = [source.id: source.name, destination.id: destination.name]
        let copy = SFTPTransfer(
            sourceHostID: source.id,
            destinationHostID: destination.id,
            direction: .copy,
            localPath: "/home/source/in/file.txt",
            remotePath: "/home/destination/out/file.txt",
            sourceHomeDirectory: "/home/source",
            destinationHomeDirectory: "/home/destination"
        )

        #expect(
            copy.routeLabel { names[$0] }
                == "Source · ~/in/file.txt → Destination · ~/out/file.txt"
        )
    }

    @Test
    func transferRoutesFallBackToTheDisplayedRemotePathForUnknownHosts() {
        let upload = SFTPTransfer(
            destinationHostID: UUID(),
            direction: .upload,
            localPath: "/Users/example/private/file.txt",
            remotePath: "/home/deploy/file.txt",
            destinationHomeDirectory: "/home/deploy"
        )

        #expect(upload.routeLabel { _ in nil } == "~/file.txt")
        var unresolved = upload
        unresolved.destinationHomeDirectory = nil
        #expect(unresolved.routeLabel { _ in nil } == "/home/deploy/file.txt")
        unresolved.destinationHostID = nil
        #expect(unresolved.routeLabel { _ in "Unused" } == "/home/deploy/file.txt")
    }

    @Test
    func transferDetailPrioritizesFailureThenThroughputThenByteProgress() {
        var transfer = SFTPTransfer(
            localPath: "/tmp/file.txt", remotePath: "/srv/file.txt",
            byteCount: 100, transferredBytes: 25, bytesPerSecond: 10, state: .failed("Offline"))

        #expect(transfer.progressDetail == "Offline")
        transfer.state = .running
        #expect(transfer.progressDetail == DataSizeFormat.rate(10))
        transfer.bytesPerSecond = 0
        #expect(transfer.progressDetail == "\(DataSizeFormat.bytes(25)) of \(DataSizeFormat.bytes(100))")
        transfer.byteCount = 0
        #expect(transfer.progressDetail == nil)
        transfer.state = .completed
        #expect(transfer.progressDetail == nil)
    }
}
