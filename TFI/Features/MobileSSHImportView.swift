import SwiftUI
import TermindApplication
import TermindDomain
import UniformTypeIdentifiers

struct MobileSSHImportView: View {
    @Bindable var model: SSHImportModel
    @Environment(\.dismiss) private var dismiss
    @State private var choosingSource = false
    @State private var knownHostsOnly = false
    @State private var authorizing = false
    @State private var unlockID: UUID?
    @State private var passphrase = ""
    @State private var fileError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Known Hosts Only", isOn: $knownHostsOnly).disabled(!model.items.isEmpty)
                    Button("Choose SSH Files") { choosingSource = true }
                    if let path = model.sourcePath { Text(path).font(.caption).foregroundStyle(.secondary) }
                    Picker("Key Storage", selection: $model.storage) {
                        Text("This Device").tag(KeyStorage.thisDevice)
                        Text("iCloud").tag(KeyStorage.iCloud)
                    }
                }
                ForEach(SSHImportCategory.allCases) { category in
                    Section(category.title) {
                        ForEach($model.items) { $item in
                            if item.category == category { row($item) }
                        }
                    }
                }
                if let error = model.error { Text(error).foregroundStyle(.red) }
                if let error = fileError { Text(error).foregroundStyle(.red) }
            }
            .disabled(model.isWorking)
            .navigationTitle("Import SSH Files")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Task {
                            await model.discard()
                            dismiss()
                        }
                    }.disabled(model.isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isWorking {
                        ProgressView()
                    } else {
                        Button("Import") {
                            Task {
                                await model.commit()
                                if model.completed { dismiss() }
                            }
                        }
                        .disabled(!model.canImport)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(model.isWorking)
        .onDisappear { Task { await model.discard() } }
        .fileImporter(isPresented: $choosingSource, allowedContentTypes: knownHostsOnly ? [.data] : [.folder]) {
            result in
            Task {
                do { await model.scan(try result.get(), knownHostsOnly: knownHostsOnly) } catch {
                    fileError = error.localizedDescription
                }
            }
        }
        .fileImporter(isPresented: $authorizing, allowedContentTypes: [.data, .folder]) { result in
            Task {
                do { await model.authorize(try result.get()) } catch { fileError = error.localizedDescription }
            }
        }
        .alert(
            "Passphrase",
            isPresented: Binding(
                get: { unlockID != nil },
                set: {
                    if !$0 {
                        unlockID = nil
                        passphrase = ""
                    }
                })
        ) {
            SecureField("Passphrase", text: $passphrase)
            Button("Unlock") {
                guard let id = unlockID else { return }
                let value = passphrase
                passphrase = ""
                unlockID = nil
                Task { await model.unlock(id, passphrase: value) }
            }
            Button("Cancel", role: .cancel) {
                passphrase = ""
                unlockID = nil
            }
        }
    }

    @ViewBuilder private func row(_ item: Binding<SSHImportItem>) -> some View {
        let value = item.wrappedValue
        VStack(alignment: .leading, spacing: 8) {
            Toggle(value.name, isOn: item.selected).disabled(!model.selectable(value))
            if value.host != nil {
                TextField("Name", text: item.name)
                TextField(
                    "Username",
                    text: Binding(
                        get: { item.wrappedValue.host?.username ?? "" }, set: { item.wrappedValue.host?.username = $0 })
                )
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                let keys = model.keyOptions(for: value)
                if keys.count > 1 {
                    Picker("Key", selection: item.preferredKeyID) {
                        Text("Automatic").tag(UUID?.none)
                        ForEach(keys) { Text($0.label).tag(Optional($0.id)) }
                    }
                }
            }
            if let problem = model.problem(for: value) { Text(problem).font(.caption).foregroundStyle(.secondary) }
            if value.requiresPassphrase { Button("Unlock Key") { unlockID = value.id } }
            if value.needsAuthorization != nil { Button("Choose Referenced File") { authorizing = true } }
            if !model.warnings(for: value).isEmpty {
                ForEach(model.warnings(for: value), id: \.self) { Text($0).font(.caption) }
                Toggle("Accept Import Warnings", isOn: item.acceptedWarnings)
            }
        }
    }
}

struct MobileSSHImportScreen: View {
    @State private var model: SSHImportModel
    init(app: MobileAppModel) { _model = State(initialValue: app.makeSSHImportModel()) }
    var body: some View { MobileSSHImportView(model: model) }
}
