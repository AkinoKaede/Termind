// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Observation
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

@MainActor
@Observable
final class MobileSFTPChannelModel {
    private(set) var path = "/"
    private(set) var homeDirectory: String?
    var pathText = "/"
    private(set) var files: [RemoteFile] = []
    var query = ""
    private(set) var backHistory: [String] = []
    private(set) var forwardHistory: [String] = []
    var operationError: String?
    private(set) var isRefreshing = false
    var sortField: RemoteFileSortField = .name
    var sortDirection: RemoteFileSortDirection = .ascending
    var showsHiddenFiles = false

    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }
    var visibleFiles: [RemoteFile] {
        let displayable = showsHiddenFiles ? files : files.filter { !$0.isHidden }
        let matches =
            query.isEmpty
            ? displayable
            : displayable.filter { $0.name.localizedCaseInsensitiveContains(query) }
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
    @ObservationIgnored private let history: SFTPHistoryModel?
    @ObservationIgnored private var connectionGeneration: UUID?
    @ObservationIgnored private var directoryRequest = UUID()
    @ObservationIgnored private var handlesConnectionError: ((any Error) -> Bool)?
    @ObservationIgnored private var didChangePath: (() -> Void)?

    init(history: SFTPHistoryModel? = nil) {
        self.history = history
    }

    func attach(
        fileSystem: any RemoteFileSystem,
        path: String,
        homeDirectory: String? = nil,
        connectionGeneration: UUID,
        handlesConnectionError: @escaping (any Error) -> Bool,
        didChangePath: @escaping () -> Void
    ) async throws {
        self.fileSystem = fileSystem
        self.homeDirectory = homeDirectory.flatMap { $0.hasPrefix("/") ? RemotePath.normalized($0) : nil }
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
        homeDirectory = nil
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
        guard let fileSystem, let connectionGeneration else { return }
        do {
            try await fileSystem.rename(file, to: name)
            guard self.connectionGeneration == connectionGeneration else { return }
            await reload()
        } catch {
            guard self.connectionGeneration == connectionGeneration else { return }
            if handlesConnectionError?(error) != true { throw error }
        }
    }

    func setPermissions(_ file: RemoteFile, mode: UInt32) async throws {
        guard let fileSystem, let connectionGeneration else { return }
        do {
            try await fileSystem.setPermissions(of: file, to: mode)
            guard self.connectionGeneration == connectionGeneration else { return }
            await reload()
        } catch {
            guard self.connectionGeneration == connectionGeneration else { return }
            if handlesConnectionError?(error) != true { throw error }
        }
    }

    func createDirectory(_ name: String) async {
        guard let fileSystem, let connectionGeneration else { return }
        do {
            try await fileSystem.createDirectory(named: name, in: path)
            guard self.connectionGeneration == connectionGeneration else { return }
            await reload()
        } catch {
            guard self.connectionGeneration == connectionGeneration else { return }
            record(error)
        }
    }

    func delete(_ file: RemoteFile) async {
        guard let fileSystem, let connectionGeneration else { return }
        do {
            try await fileSystem.remove(file)
            guard self.connectionGeneration == connectionGeneration else { return }
            await reload()
        } catch {
            guard self.connectionGeneration == connectionGeneration else { return }
            record(error)
        }
    }

    private func record(_ error: any Error) {
        if handlesConnectionError?(error) != true {
            operationError = error.localizedDescription
        }
    }

    private func recordDirectory(_ path: String) {
        history?.record(kind: .directory, path: path)
    }
}
