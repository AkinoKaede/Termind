import SwiftUI
import TermindApplication
import TermindPresentation
import UIKit
import UniformTypeIdentifiers

struct MobileLoggingView: View {
    let logging: any ApplicationLogManaging
    @AppStorage(SettingsKey.loggingSavingEnabled) private var loggingSavingEnabled = false
    @AppStorage(SettingsKey.loggingLevel) private var loggingLevel = ApplicationLogLevel.info.rawValue
    @State private var files: [ApplicationLogFile] = []
    @State private var selectedFile: ApplicationLogFile?
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
        .navigationTitle(TermindCopy.Settings.logging.swiftUIKey)
        .toolbar {
            if !files.isEmpty {
                MobileToolbarOverflow {
                    Button(TermindCopy.Common.deleteAll.swiftUIKey, systemImage: "trash", role: .destructive) {
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
            TermindCopy.Settings.deleteAllLoggingFilesConfirmation.swiftUIKey, isPresented: $showsDeleteAll,
            titleVisibility: .visible
        ) {
            Button(TermindCopy.Common.deleteAll.swiftUIKey, role: .destructive) { perform { try logging.deleteAll() } }
        }
        .alert(TermindCopy.Settings.logging.swiftUIKey, isPresented: errorPresented) {
            Button(TermindCopy.Common.ok.swiftUIKey, role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var loggingOptionsSection: some View {
        LoggingSettingsSection(saving: savingBinding, level: levelBinding)
    }

    @ViewBuilder
    private var logsSection: some View {
        Section(TermindCopy.Settings.logs.swiftUIKey) {
            if files.isEmpty {
                ContentUnavailableView(TermindCopy.Settings.noSavedLogs.swiftUIKey, systemImage: "doc.text")
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
            LoggingFileLabel(file: file, dateFormat: .dateTime.year().month().day().hour().minute())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(TermindCopy.Common.save.swiftUIKey, systemImage: "square.and.arrow.down") {
                prepare(file, action: .save)
            }
            Button(TermindCopy.Common.share.swiftUIKey, systemImage: "square.and.arrow.up") {
                prepare(file, action: .share)
            }
            Divider()
            Button(TermindCopy.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                perform { try logging.delete(file.id) }
            }
        }
        .swipeActions {
            Button(TermindCopy.Common.delete.swiftUIKey, role: .destructive) { perform { try logging.delete(file.id) } }
        }
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
                        TermindCopy.Settings.logExportWarning.swiftUIKey,
                        systemImage: "hand.raised.fill"
                    )
                }
                Section {
                    Button(TermindCopy.Common.save.swiftUIKey, systemImage: "square.and.arrow.down", action: save)
                    Button(TermindCopy.Common.share.swiftUIKey, systemImage: "square.and.arrow.up", action: share)
                }
            }
            .navigationTitle(TermindCopy.Settings.shareLogging.swiftUIKey)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(TermindCopy.Common.close.swiftUIKey, systemImage: "xmark") { dismiss() }
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
