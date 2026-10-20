// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

#if os(iOS)
    import SwiftUI
    import TermindApplication

    public enum OperationConfirmationPlacement {
        case anchored
        case centered
    }

    public enum OperationConfirmationText {
        case localized(LocalizedStringResource)
        case verbatim(String)

        public init(_ resource: LocalizedStringResource) { self = .localized(resource) }
        public init(_ value: String) { self = .verbatim(value) }

        fileprivate func resolve(locale: Locale) -> String {
            switch self {
            case .localized(let resource): AppLocalization.resolve(resource, locale: locale)
            case .verbatim(let value): value
            }
        }
    }

    public struct OperationConfirmationAction {
        let title: LocalizedStringResource
        let role: ButtonRole?
        let perform: () -> Void

        public init(_ title: LocalizedStringResource, role: ButtonRole? = nil, action: @escaping () -> Void) {
            self.title = title
            self.role = role
            perform = action
        }
    }

    /// The app provides centered confirmations; anchored confirmations use SwiftUI's native source transition.
    public struct OperationConfirmationRequest {
        public struct Action {
            public let title: String
            public let role: ButtonRole?
            public let perform: () -> Void
        }

        public let title: String
        public let message: String?
        public let isPresented: Binding<Bool>
        public let placement: OperationConfirmationPlacement
        public let actions: [Action]
    }

    public typealias OperationConfirmationRenderer = @MainActor @Sendable (OperationConfirmationRequest) -> AnyView

    extension EnvironmentValues {
        @Entry public var operationConfirmationRenderer: OperationConfirmationRenderer? = nil
    }

    extension View {
        public func operationConfirmation(
            _ title: OperationConfirmationText, isPresented: Binding<Bool>,
            placement: OperationConfirmationPlacement = .anchored,
            actions: [OperationConfirmationAction], message: OperationConfirmationText? = nil
        ) -> some View {
            modifier(
                OperationConfirmation(
                    title: title, isPresented: isPresented, placement: placement, actions: actions, message: message))
        }
    }

    private struct OperationConfirmation: ViewModifier {
        let title: OperationConfirmationText
        @Binding var isPresented: Bool
        let placement: OperationConfirmationPlacement
        let actions: [OperationConfirmationAction]
        let message: OperationConfirmationText?
        @Environment(\.locale) private var locale
        @Environment(\.operationConfirmationRenderer) private var renderer

        func body(content: Content) -> some View {
            if let renderer, placement == .centered {
                content.background {
                    renderer(
                        OperationConfirmationRequest(
                            title: title.resolve(locale: locale), message: message?.resolve(locale: locale),
                            isPresented: $isPresented, placement: placement,
                            actions: actions.map {
                                .init(
                                    title: AppLocalization.resolve($0.title, locale: locale), role: $0.role,
                                    perform: $0.perform)
                            }))
                }
            } else {
                content.confirmationDialog(
                    Text(verbatim: title.resolve(locale: locale)), isPresented: $isPresented,
                    titleVisibility: .visible
                ) {
                    ForEach(actions.indices, id: \.self) { index in
                        // Keep the explicit Cancel visible in the floating menu; SwiftUI owns outside dismissal.
                        Button(
                            role: actions[index].role == .cancel ? nil : actions[index].role,
                            action: actions[index].perform
                        ) {
                            Text(actions[index].title)
                        }
                    }
                } message: {
                    if let message { Text(verbatim: message.resolve(locale: locale)) }
                }
            }
        }
    }
#endif
