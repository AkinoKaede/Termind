import AgentKit
import SwiftUI
import TermindApplication
import UniformTypeIdentifiers

public struct MemorySettingsSection: View {
    /// A section embeds its actions; a page owns its form and navigation toolbar.
    public enum Layout { case section, page }

    @Bindable private var memory: MemoryModel
    private let ai: AIConfigurationModel
    private let layout: Layout
    @State private var confirmDestroy = false
    @State private var editing: AgentMemoryTarget?
    @State private var draft = ""
    @State private var exporting = false
    @State private var exportError: String?
    public init(memory: MemoryModel, ai: AIConfigurationModel, layout: Layout = .section) {
        self.memory = memory
        self.ai = ai
        self.layout = layout
    }
    public var body: some View {
        Group {
            if layout == .page {
                Form { section }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                if memory.isEnabled {
                                    exportButton
                                    rebuildButton
                                    Divider()
                                }
                                destroyButton
                            } label: {
                                Image(systemName: "ellipsis").accessibilityLabel(Text(AppStrings.Common.more))
                            }
                        }
                    }
            } else {
                section
            }
        }
        .task { await memory.refresh() }
        .confirmationDialog("Destroy Memory?", isPresented: $confirmDestroy, titleVisibility: .visible) {
            Button("Destroy", role: .destructive) { Task { await memory.destroy() } }
        } message: {
            Text(AppStrings.Settings.hermesDestroyDescription)
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            NavigationStack {
                Form {
                    TextEditor(text: $draft).frame(minHeight: 220)
                    if let error = memory.error { Text(error).foregroundStyle(.red) }
                    if editing != nil {
                        Text(
                            AppStrings.Settings.hermesMemoryUsage(
                                entries: draft.components(separatedBy: "\n§\n").filter { !$0.isEmpty }.count,
                                characters: draft.unicodeScalars.count)
                        ).monospacedDigit()
                    }
                }
                .navigationTitle(editing == .memory ? "Memory Notes" : "User Profile")
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(AppStrings.Common.cancel.swiftUIKey, systemImage: "xmark") { editing = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(AppStrings.Common.save.swiftUIKey, systemImage: "checkmark") {
                            guard let target = editing else { return }
                            Task {
                                await memory.edit(target, text: draft)
                                if memory.error == nil { editing = nil }
                            }
                        }
                        .disabled(memory.isBusy)
                        #if os(iOS)
                            .tint(.blue)
                        #endif
                    }
                }
                #if os(iOS)
                    .labelStyle(.iconOnly)
                #else
                    .labelStyle(.titleOnly)
                #endif
            }.frame(minWidth: 320, minHeight: 360)
        }
        .fileExporter(
            isPresented: $exporting, document: KnowledgeFileDocument(data: Data(memory.state.prompt.utf8)),
            contentType: .plainText, defaultFilename: "Memory.md"
        ) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
    }

    private var section: some View {
        Section {
            Toggle(
                AppStrings.Common.enabled.swiftUIKey,
                isOn: Binding(
                    get: { memory.isEnabled },
                    set: { enabled in
                        Task { await memory.setEnabled(enabled) }
                    })
            ).disabled(memory.isBusy)
            Text(AppStrings.Settings.hermesPolicyDescription)
                .font(.caption).foregroundStyle(.secondary)
            if memory.isEnabled {
                Toggle("Automatic Learning", isOn: $memory.reviewEnabled)
                Picker("Learning Model", selection: $memory.reviewModel) {
                    Text("Same as Chat").tag(AIModelRef?.none)
                    ForEach(ai.enabledModelProviders) { provider in
                        Section(provider.name) {
                            ForEach(provider.chatModels) { model in
                                Text(model.label).tag(
                                    AIModelRef?.some(.init(modelProviderID: provider.id, modelID: model.id)))
                            }
                        }
                    }
                }
                Text(AppStrings.Settings.hermesLearningDescription)
                    .font(.caption).foregroundStyle(.secondary)
                #if os(macOS)
                    VStack(spacing: 8) { memoryRows }
                #else
                    memoryRows
                #endif
            }
            if let error = exportError ?? memory.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if layout == .section {
                HStack(spacing: 8) {
                    if memory.isEnabled {
                        exportButton
                        rebuildButton
                    }
                    Spacer(minLength: 16)
                    destroyButton
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .labelStyle(.titleOnly)
            }
            if memory.isEnabled && memory.isIndexing {
                ProgressView("Indexing History")
                    #if os(macOS)
                        .controlSize(.small)
                    #endif
            }
            if memory.isBusy { ProgressView() }
        } header: {
            if layout == .section { Text(AppStrings.Settings.hermesMemory) }
        }
    }

    private var memoryRows: some View {
        ForEach(AgentMemoryTarget.allCases, id: \.self) { target in
            let usage = memory.state.usage(target)
            let count = memory.state.entries.filter { $0.target == target }.count
            Button {
                draft = memory.state.text(target)
                editing = target
            } label: {
                HStack {
                    Text(target == .memory ? "Memory Notes" : "User Profile")
                    Spacer()
                    Text(AppStrings.Settings.hermesMemoryUsage(entries: count, characters: usage))
                        .monospacedDigit().foregroundStyle(.secondary)
                    #if os(macOS)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    #endif
                }
                #if os(macOS)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
                    .clipShape(.rect(cornerRadius: 6))
                #endif
                .contentShape(.rect)
            }
            #if os(macOS)
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(target == .memory ? "Memory Notes" : "User Profile"))
                .accessibilityValue(Text(AppStrings.Settings.hermesMemoryUsage(entries: count, characters: usage)))
            #endif
        }
    }

    private var exportButton: some View {
        Button(AppStrings.Common.export.swiftUIKey, systemImage: "square.and.arrow.up") {
            exporting = true
        }
    }

    private var rebuildButton: some View {
        Button("Rebuild", systemImage: "arrow.clockwise") {
            Task { await memory.rebuildHistoryIndex() }
        }
        .disabled(memory.isIndexing)
    }

    private var destroyButton: some View {
        Button("Destroy", systemImage: "trash", role: .destructive) { confirmDestroy = true }.disabled(memory.isBusy)
    }
}

public struct KnowledgeFileDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.data] }
    public var data: Data
    public init(data: Data) { self.data = data }
    public init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

public struct SkillPackageDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.folder] }
    private var files: [String: Data]
    public init(skill: AgentSkill) throws {
        try skill.package?.validate()
        files = skill.package?.files ?? [:]
        files["SKILL.md"] = Data(AgentSkillDocument.render(skill).utf8)
    }
    public init(configuration: ReadConfiguration) throws {
        var contents: [String: Data] = [:]
        func read(_ wrapper: FileWrapper, prefix: String) throws {
            if let children = wrapper.fileWrappers {
                for (name, child) in children {
                    let path = prefix.isEmpty ? name : prefix + "/" + name
                    try AgentSkillPackage.validatePath(path)
                    try read(child, prefix: path)
                }
            } else if let bytes = wrapper.regularFileContents {
                guard contents.count < AgentSkillPackage.maximumFiles + 1,
                    bytes.count <= AgentSkillPackage.maximumFileBytes
                else { throw AgentSkillImportError.tooLarge }
                contents[prefix] = bytes
            } else {
                throw AgentSkillImportError.notReadable
            }
        }
        try read(configuration.file, prefix: "")
        guard contents.values.reduce(0, { $0 + $1.count }) <= AgentSkillPackage.maximumBytes else {
            throw AgentSkillImportError.tooLarge
        }
        files = contents
    }
    private func makeWrapper() throws -> FileWrapper {
        let root = FileWrapper(directoryWithFileWrappers: [:])
        for (path, bytes) in files.sorted(by: { $0.key < $1.key }) {
            try AgentSkillPackage.validatePath(path)
            let parts = path.components(separatedBy: "/")
            var directory = root
            for part in parts.dropLast() {
                if let existing = directory.fileWrappers?[part] {
                    guard existing.isDirectory else { throw AgentSkillImportError.notReadable }
                    directory = existing
                } else {
                    let child = FileWrapper(directoryWithFileWrappers: [:])
                    child.preferredFilename = part
                    directory.addFileWrapper(child)
                    directory = child
                }
            }
            guard directory.fileWrappers?[parts.last!] == nil else { throw AgentSkillImportError.notReadable }
            let file = FileWrapper(regularFileWithContents: bytes)
            file.preferredFilename = parts.last
            directory.addFileWrapper(file)
        }
        return root
    }
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { try makeWrapper() }
    public func write(to url: URL) throws {
        try makeWrapper().write(to: url, options: .atomic, originalContentsURL: nil)
    }
}
