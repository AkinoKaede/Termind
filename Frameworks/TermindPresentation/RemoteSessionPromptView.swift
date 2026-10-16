import SwiftUI
import TermindApplication
import TermindDomain

public struct RemoteSessionPromptView: View {
    private let coordinator: RemoteSessionCoordinator
    private let cancel: () -> Void
    @Environment(\.locale) private var locale

    public init(coordinator: RemoteSessionCoordinator, cancel: @escaping () -> Void) {
        self.coordinator = coordinator
        self.cancel = cancel
    }

    public var body: some View {
        if let prompt = coordinator.prompt {
            VStack(alignment: .leading, spacing: 16) {
                Text(AppStrings.SessionPersistence.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure = prompt.failure {
                    Text(message(for: failure))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if prompt.sessions.isEmpty {
                        Text(AppStrings.SessionPersistence.empty).foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(prompt.sessions) { session in
                                    Button {
                                        coordinator.choose(.attach(session), for: prompt.id)
                                    } label: {
                                        VStack(alignment: .leading) {
                                            Text(verbatim: session.name)
                                                .lineLimit(nil)
                                                .fixedSize(horizontal: false, vertical: true)
                                            if let windows = session.windows, let clients = session.clients {
                                                Text(
                                                    verbatim:
                                                        AppStrings.SessionPersistence.details(
                                                            windows: windows, clients: clients, locale: locale)
                                                )
                                                .font(.caption).foregroundStyle(.secondary)
                                            } else if let windows = session.windows {
                                                Text(AppStrings.SessionPersistence.windows(windows))
                                                    .font(.caption).foregroundStyle(.secondary)
                                            } else if let clients = session.clients {
                                                Text(AppStrings.SessionPersistence.clients(clients))
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }.frame(maxHeight: 280)
                    }
                }
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack {
                        cancelAction(for: prompt)
                        Spacer()
                        HStack {
                            skipAction(for: prompt)
                            primaryAction(for: prompt)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        cancelAction(for: prompt)
                        skipAction(for: prompt)
                        primaryAction(for: prompt)
                    }
                }
                #if os(iOS)
                    .controlSize(.large)
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func cancelAction(for prompt: RemoteSessionCoordinator.Prompt) -> some View {
        Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) {
            coordinator.cancelSelection(for: prompt.id) { cancel() }
        }
        .keyboardShortcut(.cancelAction)
    }

    private func skipAction(for prompt: RemoteSessionCoordinator.Prompt) -> some View {
        Button(AppStrings.Common.skip.swiftUIKey) {
            coordinator.choose(.plainShell, for: prompt.id)
        }
    }

    private func primaryAction(for prompt: RemoteSessionCoordinator.Prompt) -> some View {
        Button(prompt.failure == nil ? AppStrings.Common.new.swiftUIKey : AppStrings.Common.retry.swiftUIKey) {
            coordinator.choose(prompt.failure == nil ? .create : .retry, for: prompt.id)
        }
        .buttonStyle(.borderedProminent)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func message(for failure: RemoteSessionFailure) -> LocalizedStringResource {
        switch failure {
        case .missing: AppStrings.SessionPersistence.missing
        case .unsupported: AppStrings.SessionPersistence.unsupported
        case .startupUnavailable: AppStrings.SessionPersistence.startupUnavailable
        case .timedOut: AppStrings.SessionPersistence.timedOut
        case .sessionMissing, .ownershipMismatch: AppStrings.SessionPersistence.changed
        case .invalidResponse, .commandFailed: AppStrings.SessionPersistence.failed
        }
    }
}
