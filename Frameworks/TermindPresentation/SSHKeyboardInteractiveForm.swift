import SwiftUI
import TermindApplication

public struct SSHKeyboardInteractiveForm: View {
    private let challenge: SSHKeyboardInteractiveChallenge
    private let submit: ([String]) -> Void
    private let cancel: () -> Void
    private let keyboard: (any ConnectionFormKeyboardAdapting)?
    private let usesContainerChrome: Bool
    @State private var answers: [String]
    @State private var submitted = false
    @FocusState private var focus: Int?

    public init(
        challenge: SSHKeyboardInteractiveChallenge, submit: @escaping ([String]) -> Void,
        cancel: @escaping () -> Void, keyboard: (any ConnectionFormKeyboardAdapting)? = nil,
        usesContainerChrome: Bool = false
    ) {
        self.challenge = challenge
        self.submit = submit
        self.cancel = cancel
        self.keyboard = keyboard
        self.usesContainerChrome = usesContainerChrome
        _answers = State(initialValue: Array(repeating: "", count: challenge.prompts.count))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Interactive authentication").font(.headline)
            Text(verbatim: challenge.address).font(.caption.monospaced()).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !challenge.name.isEmpty { Text(verbatim: challenge.name).font(.headline) }
                    if !challenge.instruction.isEmpty {
                        Text(verbatim: challenge.instruction).textSelection(.enabled)
                    }
                    ForEach(challenge.prompts.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verbatim: challenge.prompts[index].text)
                            Group {
                                if challenge.prompts[index].echo {
                                    TextField("", text: $answers[index])
                                } else {
                                    SecureField("", text: $answers[index])
                                }
                            }
                            .focused($focus, equals: index)
                            .accessibilityLabel(Text(verbatim: challenge.prompts[index].text))
                            .onSubmit {
                                if index + 1 < answers.count { focus = index + 1 } else { commit() }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            .textFieldStyle(.roundedBorder)
            #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            #endif
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                if !challenge.prompts.isEmpty {
                    Button("Continue", action: commit)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(submitted)
                }
            }
        }
        .connectionFormChrome(isEnabled: usesContainerChrome)
        .background {
            if let keyboard {
                keyboard.bridge(canSubmit: !submitted, submit: commit, cancel: cancel)
            }
        }
        .task {
            focus = answers.isEmpty ? nil : 0
            // RFC 4256 also permits informational rounds without any questions.
            if challenge.prompts.isEmpty { commit() }
        }
        .onDisappear { answers = Array(repeating: "", count: answers.count) }
    }

    private func commit() {
        guard !submitted else { return }
        submitted = true
        let response = answers
        answers = Array(repeating: "", count: answers.count)
        submit(response)
    }
}
