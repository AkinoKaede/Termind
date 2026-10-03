#if os(macOS)
    import Foundation
    import TermindApplication
    import TermindDomain
    import Testing

    @testable import TermindRemoteInfrastructure

    @Suite
    struct RemoteShellHistoryLoaderTests {
        @Test func realZshHistoryPreservesBackslashesBeforeLogicalNewlines() async throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            let commands =
                (0...2).map { "echo one" + String(repeating: "\\", count: $0) + "\ntwo" }
                + ["echo end\\", "pwd"]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments =
                [
                    "-f", "-i", "-c",
                    "HISTFILE=$1; HISTSIZE=100; SAVEHIST=100; setopt EXTENDED_HISTORY; shift; "
                        + "for c in \"$@\"; do print -sr -- \"$c\"; done; fc -W \"$HISTFILE\"",
                    "history-test", file.path,
                ] + commands
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let loader = RemoteShellHistoryLoader(
                charset: .utf8, resolveSource: { nil }, execute: { command, _ in try Self.execute(command) })
            let records = try await loader.load(source: .init(shell: .zsh, path: file.path))
            #expect(records.map(\.command) == Array(commands.prefix(3)) + ["echo end\\ ", "pwd"])
        }

        @Test func execReadsQuotedPathsAsDataAndWorksWithoutIntegration() async throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("history ' quoted; $(false)")
            try Data("pwd\necho $(false)\n".utf8).write(to: file)
            let loader = RemoteShellHistoryLoader(
                charset: .utf8, resolveSource: { nil },
                execute: { command, _ in
                    try Self.execute(command, environment: ["SHELL": "/bin/bash", "HISTFILE": file.path])
                })
            let standard = try await loader.load(source: nil)
            let custom = try await loader.load(source: .init(shell: .bash, path: file.path))
            #expect(standard.map(\.command) == ["pwd", "echo $(false)"])
            #expect(custom == standard)
            #expect(standard.allSatisfy { $0.executedAt == nil })
            #expect(try String(contentsOf: file, encoding: .utf8) == "pwd\necho $(false)\n")
        }

        @Test func readsOnlyBoundedTailAndKeepsCompleteRecentRecords() async throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            var content = Data(String(repeating: "x", count: RemoteShellHistoryLoader.maximumFileBytes + 100).utf8)
            content.append(Data("\n#123\npwd\n#124\nwhoami\n".utf8))
            try content.write(to: file)
            let loader = RemoteShellHistoryLoader(
                charset: .utf8, resolveSource: { nil },
                execute: { command, _ in
                    try Self.execute(command)
                })
            let records = try await loader.load(source: .init(shell: .bash, path: file.path))
            #expect(records.map(\.command) == ["pwd", "whoami"])
        }

        @Test func missingAndExplicitlyDisabledFilesAreSuccessfulEmptyReads() async throws {
            let loader = RemoteShellHistoryLoader(
                charset: .utf8, resolveSource: { nil },
                execute: { command, _ in
                    try Self.execute(command)
                })
            #expect(try await loader.load(source: .init(shell: .zsh, path: "/nonexistent-\(UUID())")).isEmpty)
            #expect(try await loader.load(source: .init(shell: .bash, path: "")).isEmpty)
        }

        @Test func zshMetaficationAndRemoteCharsetAreDecodedBeforeParsing() async throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            let bytes = try RemoteCharsetStreamConverter.encode(": 123:0;echo 中文\n", charset: .gb18030)
            var metafied = Data()
            for byte in bytes {
                if byte >= 0x80 {
                    metafied.append(0x83)
                    metafied.append(byte ^ 0x20)
                } else {
                    metafied.append(byte)
                }
            }
            try metafied.write(to: file)
            let loader = RemoteShellHistoryLoader(
                charset: .gb18030, resolveSource: { nil },
                execute: { command, _ in
                    try Self.execute(command)
                })
            #expect(try await loader.load(source: .init(shell: .zsh, path: file.path)).map(\.command) == ["echo 中文"])
        }

        @Test func execFailureDoesNotReturnAPartialSnapshot() async {
            let loader = RemoteShellHistoryLoader(
                charset: .utf8, resolveSource: { nil },
                execute: { _, _ in
                    SSHExecResult(
                        stdout: "partial", stderr: "denied", exitCode: 1, stdoutTruncated: false, stderrTruncated: false
                    )
                })
            await #expect(throws: (any Error).self) { try await loader.load(source: nil) }
        }

        private nonisolated static func execute(_ command: String, environment: [String: String] = [:]) throws
            -> SSHExecResult
        {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, replacement in
                replacement
            }
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return SSHExecResult(
                stdout: String(decoding: bytes, as: UTF8.self), stderr: "", exitCode: process.terminationStatus,
                stdoutTruncated: false, stderrTruncated: false)
        }
    }
#endif
