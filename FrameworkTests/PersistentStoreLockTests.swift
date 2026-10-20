// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

#if os(macOS)
    import Darwin
    import Foundation
    import SwiftData
    import TermindDomain
    import Testing

    @testable import TermindPersistence

    @Suite @MainActor
    struct PersistentStoreLockTests {
        @Test func refusesAnotherOwnerBeforeOpeningOrMigratingTheStore() throws {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("Termind.store")
            let sentinel = Data("Database must not be opened while another process owns it".utf8)
            try sentinel.write(to: url)
            let owner = try PersistentStoreLock(storeURL: url)
            try withExtendedLifetime(owner) { () throws in
                #expect(throws: PersistentStoreAccessError.inUse) {
                    try TermindPersistence.makeContainer(url: url)
                }
                #expect(try Data(contentsOf: url) == sentinel)
                #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
            }
        }

        @Test func containerRetainsLockUntilItCloses() throws {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("Termind.store")
            try autoreleasepool {
                let container = try TermindPersistence.makeContainer(url: url)
                // Do not create an autosaving mainContext here: SwiftData can
                // retain it beyond this scope to process pending notifications.
                withExtendedLifetime(container) { () -> Void in
                    #expect(throws: PersistentStoreAccessError.inUse) { try PersistentStoreLock(storeURL: url) }
                }
            }
            // A leftover lock file is not a live owner. Releasing the container
            // must release its descriptor, without deleting that shared inode.
            let probe = try PersistentStoreLock(storeURL: url)
            withExtendedLifetime(probe) {}
        }

        @Test func sameProcessContainersShareLeaseUntilTheLastContainerCloses() throws {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("Termind.store")
            let alias = directory.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
            var second: ModelContainer?
            try autoreleasepool {
                let first = try TermindPersistence.makeContainer(url: url)
                first.mainContext.autosaveEnabled = false
                first.mainContext.insert(PersistentHost(Host(name: "Saved host", host: "example.com")))
                try first.mainContext.save()
                second = try TermindPersistence.makeContainer(url: alias.appendingPathComponent("Termind.store"))
            }
            #expect(throws: PersistentStoreAccessError.inUse) { try PersistentStoreLock(storeURL: url) }
            #expect(try second?.mainContext.fetchCount(FetchDescriptor<PersistentHost>()) == 1)
            second = nil
            let probe = try PersistentStoreLock(storeURL: url)
            withExtendedLifetime(probe) {}
        }

        @Test func otherProcessBlocksOpeningAndForcedExitReleasesLockWithoutLosingVault() throws {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("Termind.store")
            let host = Host(name: "Saved host", host: "example.com")
            let key = SSHKeyRef(label: "Saved key", credentialRef: "test-reference")
            try autoreleasepool {
                let container = try TermindPersistence.makeContainer(url: url)
                container.mainContext.autosaveEnabled = false
                _ = try HostPersistence(context: container.mainContext).save(.init(hosts: [host], keys: [key]))
            }

            // Use a real independent process, not another descriptor inheriting
            // this process's lease registry. Python ships with the Xcode tools.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [
                "-c",
                """
                import fcntl, sys
                with open(sys.argv[1], 'a+') as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    print('ready', flush=True)
                    sys.stdin.buffer.read(1)
                """,
                url.appendingPathExtension("lock").path,
            ]
            let output = Pipe()
            let input = Pipe()
            process.standardOutput = output
            process.standardInput = input
            try process.run()
            try output.fileHandleForWriting.close()
            defer {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            let ready = output.fileHandleForReading.readData(ofLength: 6)
            try #require(String(data: ready, encoding: .utf8) == "ready\n")
            #expect(throws: PersistentStoreAccessError.inUse) { try TermindPersistence.makeContainer(url: url) }
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("lock").path))

            let reopened = try TermindPersistence.makeContainer(url: url)
            let snapshot = try HostPersistence(context: reopened.mainContext).load()
            #expect(snapshot.hosts == [host])
            #expect(snapshot.keys == [key])
            #expect(try VaultSyncJournal(context: reopened.mainContext).pendingEnvelopes().allSatisfy { !$0.isDeleted })
        }

        @Test func separateStoresAndInMemoryContainersDoNotContend() throws {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let first = try TermindPersistence.makeContainer(url: directory.appendingPathComponent("First.store"))
            let second = try TermindPersistence.makeContainer(url: directory.appendingPathComponent("Second.store"))
            let memory = try TermindPersistence.makeContainer(inMemory: true)
            #expect(first !== second)
            #expect(memory.configurations.allSatisfy { $0.isStoredInMemoryOnly })
        }

        private func temporaryDirectory() throws -> URL {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
    }
#endif
