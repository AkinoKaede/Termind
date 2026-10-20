// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import Termind

struct SFTPLocalCopyExporterTests {
    @Test(arguments: [false, true])
    func savingACopyPreservesTheEditableSource(_ replacing: Bool) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("edited.bin")
        let destination = directory.appendingPathComponent("saved.bin")
        let data = Data([0, 255, 10, 42])
        try data.write(to: source)
        if replacing { try Data([1, 2, 3]).write(to: destination) }

        try SFTPLocalCopyExporter.copy(from: source, to: destination)

        #expect(try Data(contentsOf: source) == data)
        #expect(try Data(contentsOf: destination) == data)
    }

    @Test func failedCopyKeepsTheExistingDestination() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("saved.bin")
        let data = Data([1, 2, 3])
        try data.write(to: destination)

        #expect(throws: (any Error).self) {
            try SFTPLocalCopyExporter.copy(from: directory.appendingPathComponent("missing"), to: destination)
        }
        #expect(try Data(contentsOf: destination) == data)
    }

    @Test func selectingTheEditableFileDoesNotReplaceIt() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("edited.bin")
        let data = Data([1, 2, 3])
        try data.write(to: source)

        try SFTPLocalCopyExporter.copy(from: source, to: source)

        #expect(try Data(contentsOf: source) == data)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
