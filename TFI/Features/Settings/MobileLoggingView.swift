import SwiftUI
import TermindApplication
import UIKit
import UniformTypeIdentifiers

struct MobileLoggingView: View {
    let logging: any ApplicationLogManaging
    @AppStorage(SettingsKey.loggingSavingEnabled) private var loggingSavingEnabled = false
    @AppStorage(SettingsKey.loggingLevel) private var loggingLevel = ApplicationLogLevel.info.rawValue
    @State private var files: [ApplicationLogFile] = []
    @State private var selectedFile: ApplicationLogFile?
    @State private var pendingDelete: ApplicationLogFile?
    @State private var showsDeleteAll = false
    @State private var exportDocument: MobileLoggingFileDocument?
    @State private var exportFilename = "termind.log"
    @State private var showsExporter = false
    @State private var shareItem: MobileLoggingShareItem?
    @State private var errorMessage: String?

    var body: some View {
        List {
            loggingOptionsSection
            logsSection
        }
        .navigationTitle("Logging")
        .toolbar {
            if !files.isEmpty {
                MobileToolbarOverflow {
                    Button("Delete All", systemImage: "trash", role: .destructive) {
                        showsDeleteAll = true
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $selectedFile) { file in
            MobileLoggingShareSheet(
                save: {
                    selectedFile = nil
                    prepare(file, action: .save)
                },
                share: {
                    selectedFile = nil
                    prepare(file, action: .share)
                })
        }
        .sheet(item: $shareItem) { item in
            MobileActivityView(items: [item.url])
        }
        .fileExporter(
            isPresented: $showsExporter,
            document: exportDocument,
            contentType: UTType(filenameExtension: "log") ?? .plainText,
            defaultFilename: exportFilename
        ) { result in
            exportDocument = nil
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .confirmationDialog(
            "Delete this logging file?", isPresented: deleteFilePresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let pendingDelete else { return }
                perform { try logging.delete(pendingDelete.id) }
                self.pendingDelete = nil
            }
        }
        .confirmationDialog(
            "Delete all logging files?", isPresented: $showsDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { perform { try logging.deleteAll() } }
        }
        .alert("Logging", isPresented: errorPresented) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var loggingOptionsSection: some View {
        Section {
            Toggle("Save", isOn: savingBinding)
            Picker("Level", selection: levelBinding) {
                ForEach(ApplicationLogLevel.allCases) { level in
                    Text(verbatim: level.localizedName).tag(level.rawValue)
                }
            }
        } header: {
            Text("Logging")
        } footer: {
            Text("Logs may contain private diagnostic information. Review them before sharing.")
        }
    }

    @ViewBuilder
    private var logsSection: some View {
        Section("Logs") {
            if files.isEmpty {
                ContentUnavailableView("No Saved Logs", systemImage: "doc.text")
            } else {
                ForEach(files) { file in
                    logRow(file)
                }
            }
        }
    }

    private func logRow(_ file: ApplicationLogFile) -> some View {
        Button {
            selectedFile = file
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(file.createdAt, format: .dateTime.year().month().day().hour().minute())
                        if file.isCurrent {
                            Text("Current").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Save", systemImage: "square.and.arrow.down") {
                prepare(file, action: .save)
            }
            Button("Share", systemImage: "square.and.arrow.up") {
                prepare(file, action: .share)
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                pendingDelete = file
            }
        }
        .swipeActions {
            Button("Delete", role: .destructive) { pendingDelete = file }
        }
    }

    private var deleteFilePresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var savingBinding: Binding<Bool> {
        Binding(
            get: { loggingSavingEnabled },
            set: { value in
                do {
                    try logging.setSaving(value)
                    loggingSavingEnabled = value
                    reload()
                } catch {
                    loggingSavingEnabled = logging.isSaving
                    errorMessage = error.localizedDescription
                }
            })
    }

    private var levelBinding: Binding<String> {
        Binding(
            get: { loggingLevel },
            set: { value in
                guard let level = ApplicationLogLevel(rawValue: value) else { return }
                logging.setLevel(level)
                loggingLevel = value
            })
    }

    private func prepare(_ file: ApplicationLogFile, action: MobileLoggingExportAction) {
        do {
            let url = try logging.exportURL(for: file.id)
            switch action {
            case .save:
                exportDocument = MobileLoggingFileDocument(url: url)
                exportFilename = file.id
                showsExporter = true
            case .share:
                shareItem = MobileLoggingShareItem(url: url)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reload() {
        do { files = try logging.files() } catch { errorMessage = error.localizedDescription }
    }
}

private enum MobileLoggingExportAction { case save, share }

private struct MobileLoggingShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MobileLoggingShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let save: () -> Void
    let share: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(
                        "Logs may contain private diagnostic information. Review where you send or save them.",
                        systemImage: "hand.raised.fill"
                    )
                }
                Section {
                    Button("Save", systemImage: "square.and.arrow.down", action: save)
                    Button("Share", systemImage: "square.and.arrow.up", action: share)
                }
            }
            .navigationTitle("Share Logging")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct MobileLoggingFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "log") ?? .plainText] }
    let url: URL

    init(url: URL) { self.url = url }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("log")
        try data.write(to: url)
        self.url = url
    }
    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url)
    }
}

private struct MobileActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
