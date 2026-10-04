import SwiftUI
import TermindApplication
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["TERMIND_MOBILE_UI_TESTS"] == "1",
        "Set TERMIND_MOBILE_UI_TESTS=1 and disable parallel testing for key-window integration tests"),
    .serialized)
@MainActor
struct MobileOperationConfirmationTests {
    @Test(arguments: [false, true], ["en", "zh-Hans", "zh-Hant"])
    func nativeConfirmationUsesItsSourceAndStacksActions(centered: Bool, language: String) async throws {
        let state = ConfirmationFixtureState()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(
            rootView: ConfirmationFixture(state: state, centered: centered)
                .environment(\.locale, Locale(identifier: language))
                .mobileOperationConfirmations())
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(400))
        state.isPresented = true
        for _ in 0..<100 where findAlert(host)?.transitionCoordinator == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(60))
        let entering = try #require(findAlert(host))
        if UIView.areAnimationsEnabled && !UIAccessibility.isReduceMotionEnabled {
            #expect(entering.isBeingPresented)
        }
        try await Task.sleep(for: .milliseconds(700))
        let alert = try #require(findAlert(host))
        #expect(alert.preferredStyle == .actionSheet)
        #expect(alert.actions.filter { $0.style != .cancel }.count == 2)
        #expect(alert.actions.first?.style == .destructive)
        #expect(state.performedCount == 0)
        let popover = try #require(alert.popoverPresentationController)
        let source = try #require(popover.sourceView)
        let anchor = source.convert(popover.sourceRect, to: window)
        if centered {
            #expect(popover.permittedArrowDirections.isEmpty)
            #expect(abs(anchor.midX - window.bounds.midX) < 1)
            #expect(abs(anchor.midY - window.bounds.midY) < 1)
        } else {
            #expect(findAnchor(host) == nil)
            #expect(source !== window)
            #expect(abs(anchor.midX - state.sourceFrame.midX) < 1)
            #expect(abs(anchor.midY - state.sourceFrame.midY) < 1)
            #expect(abs(anchor.width - state.sourceFrame.width) < 1)
        }
        let locale = Locale(identifier: language)
        let confirmTitle = AppLocalization.resolve(
            centered ? AppStrings.Common.clearHistory : AppStrings.Common.delete, locale: locale)
        let cancelTitle = AppLocalization.resolve(AppStrings.Common.cancel, locale: locale)
        let confirmLabel = try #require(labels(alert.view).first { $0.text == confirmTitle })
        let cancelLabel = try #require(labels(alert.view).first { $0.text == cancelTitle })
        let confirmFrame = confirmLabel.convert(confirmLabel.bounds, to: window)
        let cancelFrame = cancelLabel.convert(cancelLabel.bounds, to: window)
        #expect(confirmFrame.maxY < cancelFrame.minY)
        #expect(abs(confirmFrame.midX - cancelFrame.midX) < 2)
        let data = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(data, named: "confirmation-\(centered ? "centered" : "anchored")-\(language).png")
        state.isPresented = false
        try await Task.sleep(for: .milliseconds(60))
        if UIView.areAnimationsEnabled && !UIAccessibility.isReduceMotionEnabled {
            #expect(alert.isBeingDismissed)
            #expect((alert.transitionCoordinator?.transitionDuration ?? 0) > 0)
        }
        try await Task.sleep(for: .milliseconds(700))
        #expect(findAlert(host) == nil)
        #expect(state.performedCount == 0)

        state.isPresented = true
        try await Task.sleep(for: .milliseconds(700))
        let reopened = try #require(findAlert(host))
        if centered {
            let presenter = try #require(findAnchor(host))
            presenter.performAfterDismissal({ state.performedCount += 1 }, from: reopened)
        } else {
            state.isPresented = false
        }
        if UIView.areAnimationsEnabled && !UIAccessibility.isReduceMotionEnabled {
            #expect(state.performedCount == 0)
        }
        try await Task.sleep(for: .milliseconds(900))
        #expect(!state.isPresented)
        #expect(findAlert(host) == nil)
        #expect(state.performedCount == (centered ? 1 : 0))
    }

    private func findAlert(_ controller: UIViewController) -> UIAlertController? {
        if let alert = controller as? UIAlertController { return alert }
        if let presented = controller.presentedViewController, let alert = findAlert(presented) { return alert }
        for child in controller.children {
            if let alert = findAlert(child) { return alert }
        }
        return nil
    }

    private func labels(_ view: UIView) -> [UILabel] {
        (view as? UILabel).map { [$0] } ?? view.subviews.flatMap(labels)
    }

    private func findAnchor(_ controller: UIViewController) -> ConfirmationAnchorController? {
        if let anchor = controller as? ConfirmationAnchorController { return anchor }
        for child in controller.children {
            if let anchor = findAnchor(child) { return anchor }
        }
        return nil
    }
}

@Observable @MainActor private final class ConfirmationFixtureState {
    var isPresented = false
    var sourceFrame: CGRect = .zero
    var performedCount = 0
}

private struct ConfirmationFixture: View {
    @Bindable var state: ConfirmationFixtureState
    let centered: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Vault").font(.largeTitle.bold())
            Spacer()
            Button("Example host") { state.isPresented = true }
                .frame(width: 260, height: 92)
                .background(.blue.opacity(0.08), in: .rect(cornerRadius: 20))
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    state.sourceFrame = $0
                }
                .operationConfirmation(
                    .init(
                        centered
                            ? AppStrings.Connections.clearConnectionHistoryConfirmation
                            : AppStrings.Vault.deleteHostConfirmation),
                    isPresented: $state.isPresented, placement: centered ? .centered : .anchored,
                    actions: [
                        .init(centered ? AppStrings.Common.clearHistory : AppStrings.Common.delete, role: .destructive)
                        {
                            state.performedCount += 1
                        },
                        .init(AppStrings.Common.cancel, role: .cancel) {},
                    ],
                    message: .init(
                        centered ? AppStrings.Workspace.clearHistoryWarning : AppStrings.Vault.deleteHostWarning)
                )
            Spacer().frame(height: 140)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
