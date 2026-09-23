import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct SSHImportView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    let knownHostsOnly: Bool
    @State private var model: SSHImportModel?
    var body: some View {
        Group {
            if let model {
                SSHImportContent(model: model, knownHostsOnly: knownHostsOnly, close: window.closeVaultWork)
            } else {
                ProgressView()
            }
        }
        .task { if model == nil { model = app.makeSSHImportModel() } }
        .onDisappear { if let model { Task { await model.discard() } } }
    }
}

private struct SSHImportContent: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: SSHImportModel
    let knownHostsOnly: Bool
    let close: () -> Void
    @State private var passphrases: [UUID: String] = [:]
    @State private var editingNames: Set<UUID> = []
    @State private var nativeDropKind: NativeDropKind?
    @State private var inputError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VaultDetailScaffold(
            title: knownHostsOnly ? TermindCopy.KnownHosts.importKnownHosts : TermindCopy.Vault.importSshFolder,
            symbol: "square.and.arrow.down",
            close: closeWhenIdle
        ) {
            if model.completed {
                VStack(alignment: .leading, spacing: Metrics.Space.m) {
                    Label(TermindCopy.Vault.importComplete.swiftUIKey, systemImage: "checkmark.circle").font(.headline)
                    Text(TermindCopy.Vault.importedItems(model.importedCount)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding()
            } else {
                Form {
                    Section {
                        sourcePicker
                    }
                    if !knownHostsOnly {
                        Section {
                            Picker(TermindCopy.Keychain.storeIn.swiftUIKey, selection: $model.storage) {
                                ForEach(PasswordStorage.allCases) { storage in
                                    Label(storage.displayName, systemImage: storage.symbol).tag(storage)
                                }
                            }
                            LabeledContent(TermindCopy.Vault.color.swiftUIKey) {
                                ColorTagPicker(selection: $model.importColor, layout: .compact)
                            }
                        }
                        Section(TermindCopy.Vault.hosts.swiftUIKey) {
                            Picker(TermindCopy.Vault.group.swiftUIKey, selection: $model.hostGroupID) {
                                Text(TermindCopy.Common.none).tag(HostGroup.ID?.none)
                                ForEach(app.hostLibrary.groups) { group in
                                    Text(group.name).tag(HostGroup.ID?.some(group.id))
                                }
                            }
                            VStack(alignment: .leading, spacing: Metrics.Space.s) {
                                Text(TermindCopy.Vault.tags)
                                TagField(tags: $model.hostTags, suggestions: app.hostLibrary.allTags)
                            }
                        }
                    }
                    if !model.items.isEmpty {
                        Section {
                            selectionButton(category: nil, title: String(localized: TermindCopy.Common.selectAll))
                        }
                        ForEach(SSHImportCategory.allCases) { category in
                            if model.items.contains(where: { $0.category == category }) {
                                Section {
                                    categoryHeader(category)
                                    if model.expanded.contains(category) {
                                        ForEach(model.items.filter { $0.category == category }) { item in
                                            itemRow(binding(for: item))
                                                .id(item.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if let issue = model.routeProblem {
                        Section {
                            Text(issue).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    if let error = inputError ?? model.error {
                        Section {
                            Text(error).foregroundStyle(.red)
                        }
                    }
                }
                .formStyle(.grouped)
                .disabled(model.isWorking)
            }
        } footer: {
            VStack(alignment: .leading, spacing: Metrics.Space.s) {
                HStack {
                    if !model.items.isEmpty && !model.completed {
                        Text(TermindCopy.Common.selected(model.selectedItems().count))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(
                        model.completed ? TermindCopy.Common.done.swiftUIKey : TermindCopy.Common.cancel.swiftUIKey,
                        action: close
                    ).disabled(model.isWorking)
                    if !model.completed {
                        Button(TermindCopy.Common.import.swiftUIKey) {
                            Task {
                                await model.commit()
                                passphrases = [:]
                            }
                        }
                        .buttonStyle(.borderedProminent).disabled(!model.canImport)
                    }
                }
            }.padding()
        }
        .overlay {
            if nativeDropKind != nil {
                DropTargetOverlay(
                    presentation: DropTargetPresentation(
                        title: String(localized: TermindCopy.Common.dragToImport),
                        detail: knownHostsOnly
                            ? String(localized: TermindCopy.Vault.knownHostsFile)
                            : String(localized: TermindCopy.Vault.sshFolder),
                        systemImage: knownHostsOnly ? "touchid" : "folder"
                    ))
            }
        }
        .overlay {
            NativeDropTarget(
                targetedKind: $nativeDropKind, acceptedKinds: [.files],
                isEnabled: !model.isWorking && !model.completed,
                receive: { receiveDrop($0.fileURLs) })
        }
        .animation(Motion.dropTarget(reduceMotion: reduceMotion), value: nativeDropKind)
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            Label(
                knownHostsOnly ? TermindCopy.Vault.knownHostsFile.swiftUIKey : TermindCopy.Vault.sshFolder.swiftUIKey,
                systemImage: knownHostsOnly ? "touchid" : "folder"
            )
            .font(.headline)
            if let source = model.sourcePath {
                Text(verbatim: source).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            } else {
                Text(
                    knownHostsOnly
                        ? TermindCopy.Vault.dropAKnownHostsFileHereOrChooseAFile
                        : TermindCopy.Vault.dropASshFolderHereOrChooseAFolder
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Button(TermindCopy.Common.choose.swiftUIKey) {
                Task {
                    if let url = await SSHImportFilePicker.choose(folder: !knownHostsOnly) {
                        inputError = nil
                        passphrases = [:]
                        await model.scan(url, knownHostsOnly: knownHostsOnly)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func receiveDrop(_ urls: [URL]) -> Bool {
        guard urls.count == 1, let url = urls.first else {
            inputError = (knownHostsOnly ? SSHImportSourceError.expectedFile : .expectedFolder).localizedDescription
            return false
        }
        inputError = nil
        passphrases = [:]
        Task { await model.scan(url, knownHostsOnly: knownHostsOnly) }
        return true
    }

    private func closeWhenIdle() { if !model.isWorking { close() } }

    private func selectionButton(category: SSHImportCategory?, title: String) -> some View {
        let total = model.availableItems(category).count
        let selected = model.selectedItems(category).count
        let symbol = selected == 0 ? "square" : selected == total ? "checkmark.square.fill" : "minus.square.fill"
        return Button {
            model.setSelected(selected != total, category: category)
        } label: {
            HStack {
                Image(systemName: symbol)
                Text(title)
                Spacer()
                Text("\(selected) / \(total)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(
            selected == 0
                ? String(localized: TermindCopy.Vault.noneSelected)
                : selected == total
                    ? String(localized: TermindCopy.Vault.allSelected)
                    : String(localized: TermindCopy.Vault.partiallySelected)
        )
        .disabled(total == 0)
    }

    private func categoryHeader(_ category: SSHImportCategory) -> some View {
        HStack {
            Button {
                if model.expanded.contains(category) {
                    model.expanded.remove(category)
                } else {
                    model.expanded.insert(category)
                }
            } label: {
                Image(systemName: model.expanded.contains(category) ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(category.title)
            selectionButton(category: category, title: category.title)
        }.font(.headline)
    }

    private func binding(for item: SSHImportItem) -> Binding<SSHImportItem> {
        Binding {
            model.item(item.id) ?? item
        } set: { updated in
            model.updateItem(updated)
        }
    }

    private func sourceLabel(_ source: String) -> String {
        guard let root = model.sourcePath else { return source }
        if source.hasPrefix(root + "/") { return String(source.dropFirst(root.count + 1)) }
        if source.hasPrefix(root + ":") {
            return URL(fileURLWithPath: root).lastPathComponent + source.dropFirst(root.count)
        }
        return source
    }

    private func itemRow(_ binding: Binding<SSHImportItem>) -> some View {
        let item = binding.wrappedValue
        return VStack(alignment: .leading, spacing: Metrics.Space.s) {
            HStack(alignment: .center, spacing: Metrics.Space.s) {
                Toggle(
                    item.name,
                    isOn: Binding(
                        get: { model.isSelected(item.id) },
                        set: { model.setSelected($0, itemID: item.id) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.checkbox)
                .fixedSize()
                .accessibilityLabel(item.name)
                .accessibilityHint(item.source)
                VStack(alignment: .leading) {
                    Text(item.name).fontWeight(.medium).lineLimit(2)
                    Text(sourceLabel(item.source)).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(
                        item.source)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture {
                    if model.selectable(item) { model.setSelected(!model.isSelected(item.id), itemID: item.id) }
                }
                .accessibilityHidden(true)
            }
            .disabled(!model.selectable(item))
            if item.existingID != nil {
                Label(TermindCopy.Vault.alreadyImported.swiftUIKey, systemImage: "checkmark.circle").font(.caption)
                    .foregroundStyle(.secondary)
            }
            if item.host != nil && model.selectable(item) {
                if model.hasNameConflict(item) || editingNames.contains(item.id) {
                    TextField(
                        TermindCopy.Common.name.swiftUIKey,
                        text: Binding(
                            get: { binding.name.wrappedValue },
                            set: {
                                editingNames.insert(item.id)
                                model.setName($0, for: item.id)
                            }
                        ).singleLineText, axis: .horizontal
                    ).singleLinePaste().lineLimit(1)
                }
                let options = model.keyOptions(for: item)
                if options.count > 1 {
                    Picker(
                        TermindCopy.Vault.key.swiftUIKey,
                        selection: Binding(
                            get: { model.chosenKey(for: item)?.id },
                            set: { model.setPreferredKey($0, for: item.id) })
                    ) {
                        ForEach(options) { key in Text(key.label).tag(Optional(key.id)) }
                    }
                }
            }
            if item.host != nil {
                LabeledContent(
                    TermindCopy.Vault.identity.swiftUIKey,
                    value: model.identityName(for: item) ?? String(localized: TermindCopy.Common.none))
            }
            if let identity = item.identity {
                if model.selectable(item) {
                    TextField(
                        TermindCopy.Common.name.swiftUIKey,
                        text: Binding(
                            get: { binding.name.wrappedValue },
                            set: { model.setName($0, for: item.id) }
                        ).singleLineText, axis: .horizontal
                    ).singleLinePaste().lineLimit(1)
                }
                LabeledContent(TermindCopy.Vault.username.swiftUIKey, value: identity.username)
                LabeledContent(
                    TermindCopy.Vault.key.swiftUIKey,
                    value: identity.keyID.flatMap { id in
                        model.keyName(id)
                    } ?? String(localized: TermindCopy.Vault.noKey)
                )
                let hosts = model.linkedHostNames(for: item)
                if !hosts.isEmpty {
                    LabeledContent(TermindCopy.Vault.hosts.swiftUIKey, value: hosts.joined(separator: ", "))
                }
            }
            if item.requiresPassphrase {
                RevealableSecretField(
                    TermindCopy.Keychain.passphrase,
                    text: Binding(get: { passphrases[item.id] ?? "" }, set: { passphrases[item.id] = $0 }),
                    prompt: Text(TermindCopy.Keychain.passphrase)
                )
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Metrics.Space.m)
                Button(TermindCopy.Vault.unlockKey.swiftUIKey) {
                    let passphrase = passphrases.removeValue(forKey: item.id) ?? ""
                    Task { await model.unlock(item.id, passphrase: passphrase) }
                }
            }
            if let path = item.needsAuthorization {
                Button(TermindCopy.Vault.authorizeFile.swiftUIKey) {
                    Task {
                        if let url = await SSHImportFilePicker.choose(folder: path.contains("*"), suggestedPath: path) {
                            await model.authorize(url)
                        }
                    }
                }
            }
            let warnings = model.warnings(for: item)
            if !warnings.isEmpty {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
                Toggle(TermindCopy.Vault.acceptTheseImportWarnings.swiftUIKey, isOn: binding.acceptedWarnings)
                    .toggleStyle(.checkbox)
            }
            if let issue = model.problem(for: item, includeWarningReminder: false), item.existingID == nil {
                Text(issue).font(.caption).foregroundStyle(item.unavailable ? Color.secondary : Color.orange)
            }
        }
    }
}
