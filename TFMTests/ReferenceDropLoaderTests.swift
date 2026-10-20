// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindPresentation
import Testing
import UniformTypeIdentifiers

@Suite
struct ReferenceDropLoaderTests {
    @Test func readsDraggedText() async throws {
        let provider = NSItemProvider(object: "termind-fido2-v1:reference" as NSString)
        #expect(try await ReferenceDropLoader.load(provider) == "termind-fido2-v1:reference")
    }

    @Test func readsDraggedFileURL() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "reference from file".write(to: url, atomically: true, encoding: .utf8)
        let provider = NSItemProvider(object: url as NSURL)
        #expect(try await ReferenceDropLoader.load(provider) == "reference from file")
    }

    @Test func readsTemporaryFileRepresentationBeforeProviderReleasesIt() async throws {
        let provider = NSItemProvider()
        provider.suggestedName = "reference.txt"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) {
            completion in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try "temporary reference".write(to: url, atomically: true, encoding: .utf8)
                completion(url, false, nil)
            } catch { completion(nil, false, error) }
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        #expect(try await ReferenceDropLoader.load(provider) == "temporary reference")
    }

    @Test func rejectsDirectoriesAndOversizedText() async throws {
        let directory = NSItemProvider(object: FileManager.default.temporaryDirectory as NSURL)
        await #expect(throws: (any Error).self) { try await ReferenceDropLoader.load(directory) }
        let text = NSItemProvider(object: String(repeating: "a", count: 1024 * 1024 + 1) as NSString)
        await #expect(throws: (any Error).self) { try await ReferenceDropLoader.load(text) }
    }
}
