import AppKit
import SwiftUI
import TermindApplication
import TermindPresentation
import UniformTypeIdentifiers

struct LoggingFilesSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.loggingSavingEnabled) private var loggingSavingEnabled = false
    @AppStorage(SettingsKey.loggingLevel) private var loggingLevel = ApplicationLogLevel.info.rawValue
    @State private var files: [ApplicationLogFile] = []
    @State private var selectedFile: ApplicationLogFile?
    @State private var showsDeleteAll = false
    @State private var exportDocument: LoggingFileDocument?
    @State private var exportFilename = "termind.log"
    @State private var showsExporter = false
    @State private var shareURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            loggingOptionsSection
            logsSection
            deleteAllSection
        }
        .onAppear(perform: reload)
        .sheet(item: $selectedFile) { file in
            LoggingShareSheet(
                save: {
                    selectedFile = nil
                    prepare(file, action: .save)
                },
                share: {
                    selectedFile = nil
                    prepare(file, action: .share)
                }
            )
            .allowsApplicationTerminationWhenModal()
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
        .background(LoggingSharingService(url: $shareURL))
        .confirmationDialog(
            AppStrings.Settings.deleteAllLoggingFilesConfirmation, isPresented: $showsDeleteAll,
            titleVisibility: .visible
        ) {
            Button(AppStrings.Common.deleteAll.swiftUIKey, role: .destructive) {
                perform { try app.logging.deleteAll() }
            }
        }
        .alert(AppStrings.Settings.logging, isPresented: errorPresented) {
            Button(AppStrings.Common.ok.swiftUIKey, role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var loggingOptionsSection: some View {
        LoggingSettingsSection(saving: savingBinding, level: levelBinding)
            .toggleStyle(.switch)
    }

    @ViewBuilder
    private var logsSection: some View {
        Section(AppStrings.Settings.logs.swiftUIKey) {
            if files.isEmpty {
                Text(AppStrings.Settings.noSavedLogsLabel).foregroundStyle(.secondary)
            } else {
                ForEach(files) { file in
                    logRow(file)
                }
            }
        }
    }

    @ViewBuilder
    private var deleteAllSection: some View {
        if !files.isEmpty {
            Section {
                Button(AppStrings.Common.deleteAll.swiftUIKey, role: .destructive) { showsDeleteAll = true }
            }
        }
    }

    private func logRow(_ file: ApplicationLogFile) -> some View {
        Button {
            selectedFile = file
        } label: {
            LoggingFileLabel(
                file: file,
                dateFormat: .dateTime.year().month().day().hour().minute().second()
            )
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(AppStrings.Common.save.swiftUIKey, systemImage: "square.and.arrow.down") {
                prepare(file, action: .save)
            }
            Button(AppStrings.Common.share.swiftUIKey, systemImage: "square.and.arrow.up") {
                prepare(file, action: .share)
            }
            Divider()
            DestructiveMenuButton(AppStrings.Common.delete) {
                perform { try app.logging.delete(file.id) }
            }
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
                    try app.logging.setSaving(value)
                    loggingSavingEnabled = value
                    reload()
                } catch {
                    loggingSavingEnabled = app.logging.isSaving
                    errorMessage = error.localizedDescription
                }
            })
    }

    private var levelBinding: Binding<String> {
        Binding(
            get: { loggingLevel },
            set: { value in
                guard let level = ApplicationLogLevel(rawValue: value) else { return }
                app.logging.setLevel(level)
                loggingLevel = value
            })
    }

    private func prepare(_ file: ApplicationLogFile, action: LoggingExportAction) {
        do {
            let url = try app.logging.exportURL(for: file.id)
            switch action {
            case .save:
                exportDocument = LoggingFileDocument(url: url)
                exportFilename = file.id
                showsExporter = true
            case .share:
                shareURL = url
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
        do { files = try app.logging.files() } catch { errorMessage = error.localizedDescription }
    }
}

private enum LoggingExportAction { case save, share }

private struct LoggingShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let save: () -> Void
    let share: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(AppStrings.Settings.shareLogging).font(.title2.bold())
            Label(
                AppStrings.Settings.logExportWarning.swiftUIKey,
                systemImage: "hand.raised.fill"
            )
            .foregroundStyle(.secondary)
            HStack {
                Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { dismiss() }
                Spacer()
                Button(AppStrings.Common.save.swiftUIKey) { save() }
                Button(AppStrings.Common.share.swiftUIKey) { share() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

private struct LoggingFileDocument: FileDocument {
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

private struct LoggingSharingService: NSViewRepresentable {
    @Binding var url: URL?

    func makeNSView(context _: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context _: Context) {
        guard let url else { return }
        DispatchQueue.main.async {
            NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            self.url = nil
        }
    }
}
