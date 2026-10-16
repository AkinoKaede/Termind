import SwiftUI
import TermindApplication

public struct TerminalTransportStatusView: View {
    private let state: ResumableTerminalState?
    private let retry: () -> Void
    private let close: () -> Void

    public init(state: ResumableTerminalState?, retry: @escaping () -> Void, close: @escaping () -> Void) {
        self.state = state
        self.retry = retry
        self.close = close
    }

    public var body: some View {
        if state == .recovering || state == .suspended || state == .failed || state == .ended {
            VStack(spacing: 12) {
                Text(
                    state == .failed || state == .ended
                        ? AppStrings.Transports.sessionUnavailable : AppStrings.Connections.reconnecting)
                HStack {
                    if state == .recovering {
                        Button(AppStrings.Transports.retryNow.swiftUIKey, action: retry)
                    }
                    Button(AppStrings.Transports.closeSession.swiftUIKey, role: .destructive, action: close)
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        }
    }
}
