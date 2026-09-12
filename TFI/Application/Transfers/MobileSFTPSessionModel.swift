import Foundation
import Observation
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

@MainActor
@Observable
final class MobileSFTPSessionModel {
    private(set) var path = "/"
    var pathText = "/"
    private(set) var files: [RemoteFile] = []
    var query = ""
    private(set) var backHistory: [String] = []
    private(set) var forwardHistory: [String] = []
    var operationError: String?
    private(set) var isRefreshing = false
    var sortField: RemoteFileSortField = .name
    var sortDirection: RemoteFileSortDirection = .ascending

    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }
    var visibleFiles: [RemoteFile] {
        let matches =
            query.isEmpty
            ? files
            : files.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let descriptor = RemoteFileSortDescriptor(field: sortField, direction: sortDirection)
        return matches.sorted { descriptor.precedes($0, $1) }
    }

    func sort(by field: RemoteFileSortField) {
        if sortField == field {
            sortDirection.toggle()
        } else {
            sortField = field
            sortDirection = field.defaultDirection
        }
    }

    @ObservationIgnored private var fileSystem: (any RemoteFileSystem)?
    @ObservationIgnored private let hostID: Host.ID?
    @ObservationIgnored private let history: SFTPHistoryModel?
    @ObservationIgnored private var connectionGeneration: UUID?
    @ObservationIgnored private var directoryRequest = UUID()
    @ObservationIgnored private var handlesConnectionError: ((any Error) -> Bool)?
    @ObservationIgnored private var didChangePath: (() -> Void)?

    init(hostID: Host.ID? = nil, history: SFTPHistoryModel? = nil) {
        self.hostID = hostID
        self.history = history
    }

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
        let path = RemotePath.normalized(path)
        let entries = try await fileSystem.directoryContents(at: path)
        guard self.connectionGeneration == connectionGeneration, directoryRequest == request else { return }
        self.path = path
        pathText = path
        files = entries
        recordDirectory(path)
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
        let destination = RemotePath.normalized(directory)
        guard destination != path else {
            await reload()
            return
        }
        let source = path
        let request = UUID()
        directoryRequest = request
        do {
            let entries = try await fileSystem.directoryContents(at: destination)
            guard self.connectionGeneration == connectionGeneration, directoryRequest == request else { return }
            backHistory.append(source)
            forwardHistory.removeAll()
            path = destination
            pathText = destination
            files = entries
            recordDirectory(destination)
            didChangePath?()
        } catch {
            guard self.connectionGeneration == connectionGeneration, directoryRequest == request else { return }
            record(error)
        }
    }

    func goBack() async {
        guard let fileSystem, let connectionGeneration, let destination = backHistory.last else { return }
        let source = path
        let request = UUID()
        directoryRequest = request
        do {
            let entries = try await fileSystem.directoryContents(at: destination)
            guard self.connectionGeneration == connectionGeneration, directoryRequest == request,
                path == source, backHistory.last == destination
            else { return }
            backHistory.removeLast()
            forwardHistory.append(source)
            path = destination
            pathText = destination
            files = entries
            recordDirectory(destination)
            didChangePath?()
        } catch {
            guard self.connectionGeneration == connectionGeneration, directoryRequest == request else { return }
            record(error)
        }
    }

    func goForward() async {
        guard let fileSystem, let connectionGeneration, let destination = forwardHistory.last else { return }
        let source = path
        let request = UUID()
        directoryRequest = request
        do {
            let entries = try await fileSystem.directoryContents(at: destination)
            guard self.connectionGeneration == connectionGeneration, directoryRequest == request,
                path == source, forwardHistory.last == destination
            else { return }
            forwardHistory.removeLast()
            backHistory.append(source)
            path = destination
            pathText = destination
            files = entries
            recordDirectory(destination)
            didChangePath?()
        } catch {
            guard self.connectionGeneration == connectionGeneration, directoryRequest == request else { return }
            record(error)
        }
    }

    func reload() async {
        guard let fileSystem, let connectionGeneration, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let requestedPath = path
        let request = UUID()
        directoryRequest = request
        do {
            let entries = try await fileSystem.directoryContents(at: requestedPath)
            guard self.connectionGeneration == connectionGeneration, directoryRequest == request,
                path == requestedPath
            else { return }
            files = entries
            recordDirectory(requestedPath)
        } catch {
            guard self.connectionGeneration == connectionGeneration, directoryRequest == request else { return }
            record(error)
        }
    }

    func rename(_ file: RemoteFile, to name: String) async throws {
        guard let fileSystem else { return }
        do {
            try await fileSystem.rename(file, to: name)
            await reload()
        } catch {
            if handlesConnectionError?(error) != true { throw error }
        }
    }

    func setPermissions(_ file: RemoteFile, mode: UInt32) async throws {
        guard let fileSystem else { return }
        do {
            try await fileSystem.setPermissions(of: file, to: mode)
            await reload()
        } catch {
            if handlesConnectionError?(error) != true { throw error }
        }
    }

    func createDirectory(_ name: String) async {
        guard let fileSystem else { return }
        do {
            try await fileSystem.createDirectory(named: name, in: path)
            await reload()
        } catch {
            record(error)
        }
    }

    func delete(_ file: RemoteFile) async {
        guard let fileSystem else { return }
        do {
            try await fileSystem.remove(file)
            await reload()
        } catch {
            record(error)
        }
    }

    private func record(_ error: any Error) {
        if handlesConnectionError?(error) != true {
            operationError = error.localizedDescription
        }
    }

    private func recordDirectory(_ path: String) {
        guard let hostID else { return }
        history?.record(kind: .directory, path: path, for: hostID)
    }
}
