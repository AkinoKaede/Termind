// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation

/// Watch both the inode and its directory: many editors save by replacing the inode.
@MainActor
final class SFTPEditFileObservation {
    private let url: URL
    private let changed: () async -> Void
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var debounce: Task<Void, Never>?

    init(url: URL, changed: @escaping () async -> Void) {
        self.url = url
        self.changed = changed
        directorySource = source(for: url.deletingLastPathComponent())
        reattachFile()
    }

    deinit {
        fileSource?.cancel()
        directorySource?.cancel()
        debounce?.cancel()
    }

    private func source(for url: URL) -> (any DispatchSourceFileSystemObject)? {
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
            queue: .global(qos: .utility))
        source.setCancelHandler { @Sendable in Darwin.close(descriptor) }
        source.setEventHandler { @Sendable [weak self] in
            Task { @MainActor [weak self] in self?.scheduleChange() }
        }
        source.resume()
        return source
    }

    private func reattachFile() {
        fileSource?.cancel()
        fileSource = source(for: url)
    }

    private func scheduleChange() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            await changed()
            reattachFile()
        }
    }
}
