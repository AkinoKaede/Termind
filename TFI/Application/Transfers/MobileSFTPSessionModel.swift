import Foundation
import Observation
import TermindApplication
import TermindDomain

@MainActor
@Observable
final class MobileSFTPSessionModel {
    private(set) var path = "/"
    private(set) var files: [RemoteFile] = []
    var operationError: String?

    @ObservationIgnored private var fileSystem: (any RemoteFileSystem)?
    @ObservationIgnored private var connectionGeneration: UUID?
    @ObservationIgnored private var directoryRequest = UUID()
    @ObservationIgnored private var handlesConnectionError: ((any Error) -> Bool)?
    @ObservationIgnored private var didChangePath: (() -> Void)?

    func attach(
        fileSystem: any RemoteFileSystem,
        path: String,
        connectionGeneration: UUID,
        handlesConnectionError: @escaping (any Error) -> Bool,
        didChangePath: @escaping () -> Void
    ) async throws {
        self.fileSystem = fileSystem
        self.connectionGeneration = connectionGeneration
        self.handlesConnectionError = handlesConnectionError
        self.didChangePath = didChangePath
        operationError = nil
        let request = UUID()
        directoryRequest = request
        let entries = try await fileSystem.directoryContents(at: path)
        guard self.connectionGeneration == connectionGeneration, directoryRequest == request else { return }
        self.path = path
        files = entries
    }

    func detach() {
        fileSystem = nil
        connectionGeneration = nil
        directoryRequest = UUID()
        handlesConnectionError = nil
        didChangePath = nil
        files = []
        operationError = nil
    }

    func openDirectory(_ directory: String) async {
        guard let fileSystem, let connectionGeneration else { return }
        let request = UUID()
        directoryRequest = request
        do {
            let entries = try await fileSystem.directoryContents(at: directory)
            guard self.connectionGeneration == connectionGeneration, directoryRequest == request else { return }
            if path != directory { didChangePath?() }
            path = directory
            files = entries
        } catch {
            guard self.connectionGeneration == connectionGeneration, directoryRequest == request else { return }
            record(error)
        }
    }

    func rename(_ file: RemoteFile, to name: String) async throws {
        guard let fileSystem else { return }
        do {
            try await fileSystem.rename(file, to: name)
            await openDirectory(path)
        } catch {
            if handlesConnectionError?(error) != true { throw error }
        }
    }

    func setPermissions(_ file: RemoteFile, mode: UInt32) async throws {
        guard let fileSystem else { return }
        do {
            try await fileSystem.setPermissions(of: file, to: mode)
            await openDirectory(path)
        } catch {
            if handlesConnectionError?(error) != true { throw error }
        }
    }

    func createDirectory(_ name: String) async {
        guard let fileSystem else { return }
        do {
            try await fileSystem.createDirectory(named: name, in: path)
            await openDirectory(path)
        } catch {
            record(error)
        }
    }

    func delete(_ file: RemoteFile) async {
        guard let fileSystem else { return }
        do {
            try await fileSystem.remove(file)
            await openDirectory(path)
        } catch {
            record(error)
        }
    }

    private func record(_ error: any Error) {
        if handlesConnectionError?(error) != true {
            operationError = error.localizedDescription
        }
    }
}
