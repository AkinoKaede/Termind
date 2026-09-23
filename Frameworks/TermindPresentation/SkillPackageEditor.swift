import AgentKit
import SwiftUI
import UniformTypeIdentifiers

public struct SkillPackageEditor: View {
    @Binding private var package: AgentSkillPackage?
    private let readResource: (URL) throws -> Data
    @State private var importing = false
    @State private var exporting = false
    @State private var exportData = Data()
    @State private var exportName = "resource"
    @State private var editing = false
    @State private var path = ""
    @State private var text = ""
    @State private var error: String?
    public init(package: Binding<AgentSkillPackage?>, readResource: @escaping (URL) throws -> Data) {
        _package = package
        self.readResource = readResource
    }
    public var body: some View {
        Section("Supporting Files") {
            ForEach(package?.files.keys.sorted() ?? [], id: \.self) { path in
                HStack {
                    Button(path) {
                        self.path = path
                        text = package?.files[path].flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        editing = true
                    }.disabled(package?.files[path].flatMap { String(data: $0, encoding: .utf8) } == nil)
                    Spacer()
                    Menu {
                        Button(TermindCopy.Common.export.swiftUIKey) {
                            exportData = package?.files[path] ?? Data()
                            exportName = URL(filePath: path).lastPathComponent
                            exporting = true
                        }
                        Button(TermindCopy.Common.delete.swiftUIKey, role: .destructive) {
                            var value = package
                            value?.files.removeValue(forKey: path)
                            package = value
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            #if os(macOS)
                HStack(spacing: 8) {
                    addFileButtons
                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            #else
                addFileButtons
            #endif
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get()
                let path = "assets/" + url.lastPathComponent
                guard package?.files[path] == nil else { throw AgentSkillImportError.notReadable }
                try save(try readResource(url), at: path)
            } catch { self.error = error.localizedDescription }
        }
        .fileExporter(
            isPresented: $exporting, document: KnowledgeFileDocument(data: exportData),
            contentType: .data, defaultFilename: exportName
        ) { result in
            if case .failure(let error) = result { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                Form {
                    TextField("Relative Path", text: $path)
                    TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 240)
                    if let error { Text(error).foregroundStyle(.red) }
                }
                .navigationTitle("Supporting File")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(TermindCopy.Common.cancel.swiftUIKey) { editing = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(TermindCopy.Common.save.swiftUIKey) {
                            do {
                                try save(Data(text.utf8), at: path)
                                editing = false
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }.frame(minWidth: 320, minHeight: 360)
        }
    }
    @ViewBuilder
    private var addFileButtons: some View {
        Button("Add Text File") {
            path = "references/notes.md"
            text = ""
            editing = true
        }
        Button("Import Resource") { importing = true }
    }

    private func save(_ data: Data, at path: String) throws {
        var updated = package ?? AgentSkillPackage()
        updated.files[path] = data
        try updated.validate()
        package = updated
        error = nil
    }
}
