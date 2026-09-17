import SwiftUI
import TermindApplication
import TermindDomain

/// Hosts own placement, connections and file presentation. Only dirty records reach this view.
public struct SFTPEditUploadOverlay: View {
    let files: [SFTPEditedFile]
    let transfers: [SFTPTransfer]
    let connected: Bool
    let upload: (UUID, Bool) async -> Bool
    let resume: (UUID) -> Void
    let open: (URL) -> Void
    let discard: (UUID) async -> Void
    @State private var conflictID: UUID?
    @State private var errorDetails: String?
    @ScaledMetric private var rowHeight = 76.0

    public init(
        files: [SFTPEditedFile], transfers: [SFTPTransfer], connected: Bool,
        upload: @escaping (UUID, Bool) async -> Bool,
        resume: @escaping (UUID) -> Void, open: @escaping (URL) -> Void,
        discard: @escaping (UUID) async -> Void
    ) {
        self.files = files
        self.transfers = transfers
        self.connected = connected
        self.upload = upload
        self.resume = resume
        self.open = open
        self.discard = discard
    }

    public var body: some View {
        if !files.isEmpty {
            rows
                .frame(height: rowHeight * Double(min(files.count, 3)) + Double(min(files.count, 3) - 1))
                .frame(maxWidth: 540)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                .confirmationDialog(
                    "The remote file has changed",
                    isPresented: Binding(get: { conflictID != nil }, set: { if !$0 { conflictID = nil } }),
                    titleVisibility: .visible
                ) {
                    if let id = conflictID {
                        Button("Overwrite Remote File", role: .destructive) { send(id, replacing: true) }
                    }
                    Button("Cancel", role: .cancel) { conflictID = nil }
                } message: {
                    Text("The remote file changed or could not be verified. Replace it with your saved local changes?")
                }
                .alert(
                    "SFTP Error",
                    isPresented: Binding(
                        get: { errorDetails != nil }, set: { if !$0 { errorDetails = nil } })
                ) {
                    Button("OK", role: .cancel) { errorDetails = nil }
                } message: {
                    Text(errorDetails ?? "")
                }
        }
    }

    @ViewBuilder private var rows: some View {
        #if os(iOS)
            List(files) { file in
                row(file).frame(height: rowHeight)
                    .overlay(alignment: .bottom) {
                        if file.id != files.last?.id { Divider().padding(.horizontal, 12) }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if canDiscard(file) {
                            Button("Discard", role: .destructive) { Task { await discard(file.id) } }
                        }
                    }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, rowHeight)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        #else
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(files) { file in
                        row(file).frame(height: rowHeight)
                        if file.id != files.last?.id { Divider() }
                    }
                }
            }
        #endif
    }

    private func canDiscard(_ file: SFTPEditedFile) -> Bool {
        guard !file.isPreparing else { return false }
        guard let id = file.transferID else { return true }
        return transfers.first { $0.id == id }?.state == .paused
    }

    private func row(_ file: SFTPEditedFile) -> some View {
        let transfer = transfers.first { $0.id == file.transferID }
        return HStack(spacing: 10) {
            Image(systemName: file.displayedError == nil ? "doc" : "exclamationmark.circle")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(file.displayedError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(file.remotePath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let transfer, transfer.state == .running || transfer.state == .queued {
                    ProgressView(
                        value: transfer.byteCount > 0
                            ? min(1, Double(transfer.transferredBytes) / Double(transfer.byteCount)) : nil
                    )
                    .accessibilityLabel("Uploading changes")
                } else if let error = file.displayedError {
                    Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1).help(error)
                } else if !connected {
                    Text("Reconnect to upload changes").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action(file, transfer: transfer).controlSize(.small)
            #if os(macOS)
                Menu {
                    fileActions(file)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 16, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            #endif
        }
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .contextMenu { fileActions(file) }
    }

    @ViewBuilder private func fileActions(_ file: SFTPEditedFile) -> some View {
        if let error = file.displayedError {
            Button("Error Details", systemImage: "exclamationmark.circle") { errorDetails = error }
            Divider()
        }
        Button("Open Local Copy", systemImage: "arrow.up.right") { open(file.localURL) }
        ShareLink(item: file.localURL) { Label("Keep Local Copy", systemImage: "square.and.arrow.up") }
        Divider()
        Button("Discard", systemImage: "xmark", role: .destructive) { Task { await discard(file.id) } }
            .disabled(!canDiscard(file))
    }

    @ViewBuilder
    private func action(_ file: SFTPEditedFile, transfer: SFTPTransfer?) -> some View {
        if file.isPreparing {
            ProgressView().controlSize(.small)
        } else if let transfer {
            if transfer.state == .paused {
                Button("Resume", systemImage: "play.fill") { resume(transfer.id) }
                    .disabled(!connected || file.isInvalidated)
            } else {
                ProgressView().controlSize(.small)
            }
        } else {
            Button {
                send(file.id, replacing: false)
            } label: {
                Text(file.displayedError == nil ? "Upload" : "Retry")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .accessibilityLabel(file.displayedError == nil ? Text("Upload") : Text("Retry"))
            .buttonStyle(.borderedProminent)
            .disabled(!connected || file.isInvalidated)
        }
    }

    private func send(_ id: UUID, replacing: Bool) {
        conflictID = nil
        Task {
            if await upload(id, replacing) { conflictID = id }
        }
    }
}
