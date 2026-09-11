import SwiftUI
import TermindApplication
import TermindDomain

@MainActor
public protocol ConnectionFormKeyboardAdapting {
    func bridge(canSubmit: Bool, submit: @escaping () -> Void, cancel: @escaping () -> Void) -> AnyView
}

extension View {
    @ViewBuilder
    fileprivate func sharedConnectionFormChrome(isEnabled: Bool) -> some View {
        if isEnabled {
            padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary) }
        } else {
            self
        }
    }
}

public struct SharedSSHAuthenticationForm: View {
    let prompt: SSHAuthenticationPrompt
    let submit: (Identity.ID?, String, String?, String?, SSHKeyRef.ID?, Bool) -> Void
    let cancel: () -> Void
    var usesContainerChrome = true

    let library: HostLibraryModel
    let keyboard: (any ConnectionFormKeyboardAdapting)?
    @State private var identityID: Identity.ID?
    @State private var username: String
    @State private var password = ""
    @State private var passphrase = ""
    @State private var keyID: SSHKeyRef.ID?
    @FocusState private var focusedField: Field?

    private enum Field { case username, password, passphrase }

    public init(
        prompt: SSHAuthenticationPrompt,
        submit: @escaping (Identity.ID?, String, String?, String?, SSHKeyRef.ID?, Bool) -> Void,
        cancel: @escaping () -> Void,
        usesContainerChrome: Bool = true,
        library: HostLibraryModel, keyboard: (any ConnectionFormKeyboardAdapting)? = nil
    ) {
        self.library = library
        self.keyboard = keyboard
        self.prompt = prompt
        self.submit = submit
        self.cancel = cancel
        self.usesContainerChrome = usesContainerChrome
        _identityID = State(initialValue: prompt.selectedIdentityID)
        _username = State(initialValue: prompt.username)
        _keyID = State(initialValue: prompt.selectedKeyID)
    }

    private var needsPassphrase: Bool {
        prompt.requiresPassphrase
    }

    private var canContinue: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!needsPassphrase || !passphrase.isEmpty)
    }

    private var title: LocalizedStringKey {
        if needsPassphrase { return "Passphrase required" }
        return prompt.mode == .localIdentity
            ? "Identity required" : "Authentication required"
    }

    public var body: some View {
        form
            .sharedConnectionFormChrome(isEnabled: usesContainerChrome)
            .background {
                if let keyboard {
                    keyboard.bridge(canSubmit: canContinue, submit: { commit(save: !needsPassphrase) }, cancel: cancel)
                }
            }
            .onAppear {
                if identityID != nil, selectedIdentity == nil { identityID = nil }
                updateFocusForRequirement()
            }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(prompt.host.displayAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "key.fill").font(.title2)
                    .foregroundStyle(Color.accentColor)
            }

            if let message = prompt.failureMessage {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.caption).foregroundStyle(Color.red)
                    .textSelection(.enabled)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                if needsPassphrase {
                    GridRow {
                        Text("Passphrase").foregroundStyle(.secondary)
                        SecureField("Required for this connection", text: $passphrase)
                            .focused($focusedField, equals: .passphrase)
                    }
                } else {
                    GridRow {
                        Text("Identity").foregroundStyle(.secondary)
                        fullWidthMenu(title: identityLabel) {
                            Button {
                                identitySelection.wrappedValue = nil
                            } label: {
                                selectionMenuLabel(
                                    String(localized: "Custom"), selected: identityID == nil
                                )
                            }
                            if !library.identities.isEmpty { Divider() }
                            ForEach(library.identities) { identity in
                                Button {
                                    identitySelection.wrappedValue = identity.id
                                } label: {
                                    selectionMenuLabel(
                                        "\(identity.name) · \(identity.username)",
                                        selected: identityID == identity.id
                                    )
                                }
                            }
                        }
                    }
                    if identityID == nil {
                        GridRow {
                            Text("Username").foregroundStyle(.secondary)
                            TextField("Username", text: usernameInput)
                                .focused($focusedField, equals: .username)
                        }
                        GridRow {
                            Text("Password").foregroundStyle(.secondary)
                            SecureField("Optional", text: passwordInput)
                                .focused($focusedField, equals: .password)
                        }
                        GridRow {
                            Text("Key").foregroundStyle(.secondary)
                            fullWidthMenu(title: keyLabel) {
                                Button {
                                    keySelection.wrappedValue = nil
                                } label: {
                                    selectionMenuLabel(
                                        String(localized: "None"), selected: keyID == nil
                                    )
                                }
                                if !library.keys.isEmpty { Divider() }
                                ForEach(library.keys) { key in
                                    Button {
                                        keySelection.wrappedValue = key.id
                                    } label: {
                                        selectionMenuLabel(
                                            key.label, selected: keyID == key.id
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .textFieldStyle(.roundedBorder)
            #if os(iOS)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            #endif

            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                if needsPassphrase {
                    Button("Continue") { commit(save: false) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinue)
                } else {
                    Button("Continue") { commit(save: false) }.disabled(!canContinue)
                    Button("Save and Continue") { commit(save: true) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinue)
                }
            }
        }
    }

    private func updateFocusForRequirement() {
        if needsPassphrase {
            focusedField = .passphrase
        } else if identityID == nil {
            focusedField = username.isEmpty ? .username : .password
        } else {
            focusedField = nil
        }
    }

    private func commit(save: Bool) {
        submit(
            identityID, username, password.isEmpty ? nil : password,
            passphrase.isEmpty ? nil : passphrase, keyID, save
        )
    }

    private var selectedIdentity: Identity? {
        identityID.flatMap { library.identity($0) }
    }

    private var identityLabel: String {
        selectedIdentity.map { "\($0.name) · \($0.username)" }
            ?? String(localized: "Custom")
    }

    private var keyLabel: String {
        keyID.flatMap { library.key($0) }?.label ?? String(localized: "None")
    }

    private func fullWidthMenu<Content: View>(
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        GeometryReader { geometry in
            Menu(content: content) {
                HStack(spacing: 8) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(width: geometry.size.width, height: 28)
                .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.055))
                }
                .contentShape(Rectangle())
            }
            #if os(macOS)
                .menuStyle(.button)
                .menuIndicator(.hidden)
            #endif
            .buttonStyle(.plain)
            .frame(width: geometry.size.width, height: 28)
            .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
    }

    @ViewBuilder
    private func selectionMenuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var identitySelection: Binding<Identity.ID?> {
        Binding {
            identityID
        } set: { id in
            identityID = id
            guard let identity = id.flatMap({ library.identity($0) }) else { return }
            username = identity.username
            password = ""
            passphrase = ""
            keyID = identity.keyID
        }
    }

    private var usernameInput: Binding<String> {
        Binding {
            username
        } set: { value in
            username = value
            if value != selectedIdentity?.username { identityID = nil }
        }
    }

    private var passwordInput: Binding<String> {
        Binding {
            password
        } set: { value in
            password = value
            if !value.isEmpty { identityID = nil }
        }
    }

    private var keySelection: Binding<SSHKeyRef.ID?> {
        Binding {
            keyID
        } set: { value in
            keyID = value
            if value != selectedIdentity?.keyID { identityID = nil }
            passphrase = ""
        }
    }
}

public struct SharedSSHHostKeyConfirmationForm: View {
    let prompt: SSHHostKeyPrompt
    var displayAddress: String? = nil
    let proceed: () -> Void
    let trust: (() -> Void)?
    let deny: () -> Void
    var usesContainerChrome = true

    let keyboard: (any ConnectionFormKeyboardAdapting)?
    public init(
        prompt: SSHHostKeyPrompt, displayAddress: String? = nil, proceed: @escaping () -> Void,
        trust: (() -> Void)?, deny: @escaping () -> Void, usesContainerChrome: Bool = true,
        keyboard: (any ConnectionFormKeyboardAdapting)? = nil
    ) {
        self.prompt = prompt
        self.displayAddress = displayAddress
        self.proceed = proceed
        self.trust = trust
        self.deny = deny
        self.usesContainerChrome = usesContainerChrome
        self.keyboard = keyboard
    }

    private var observation: SSHHostKeyObservation { prompt.observation }

    private var isAdditionalKey: Bool {
        if case .additionalKey = prompt.kind { return true }
        return false
    }

    public var body: some View {
        form
            .sharedConnectionFormChrome(isEnabled: usesContainerChrome)
            .background {
                if let keyboard { keyboard.bridge(canSubmit: true, submit: { trust?() ?? proceed() }, cancel: deny) }
            }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        isAdditionalKey
                            ? "Unrecognized additional host key" : "Verify host identity"
                    )
                    .font(.headline)
                    if let displayAddress {
                        Text(displayAddress)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(
                    systemName: isAdditionalKey
                        ? "exclamationmark.triangle.fill" : "checkmark.shield.fill"
                )
                .font(.title2)
                .foregroundStyle(
                    isAdditionalKey ? Color.orange : Color.accentColor
                )
            }
            Text(explanation)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(observation.algorithm.displayName).font(.caption).foregroundStyle(.secondary)
                Text(observation.fingerprint).font(.body.monospaced()).textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.65), in: .rect(cornerRadius: 8))
            HStack {
                Button("Deny", role: .destructive, action: deny).keyboardShortcut(.cancelAction)
                Spacer()
                if let trust {
                    Button("Continue", action: proceed)
                        .help("Continue once without saving this host key")
                    Button("Trust and Continue", action: trust)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue", action: proceed)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
    }
    private var explanation: String {
        switch prompt.kind {
        case .firstUse:
            String(
                localized:
                    "No trusted key is saved for \(observation.hostname). Confirm this fingerprint before continuing."
            )
        case .additionalKey(let trustedKeyCount):
            String(
                localized:
                    "This key is not among the \(trustedKeyCount) trusted keys saved for \(observation.hostname). Verify it carefully before adding it."
            )
        }
    }
}
