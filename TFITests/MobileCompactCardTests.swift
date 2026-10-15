import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import Testing
import UIKit

@testable import TermindIOS

@Suite @MainActor
struct MobileCompactCardTests {
    @Test(arguments: [(0.0, 1), (288.0, 3), (343.0, 4), (361.0, 4), (736.0, 4), (992.0, 4)])
    func compactColumnsFitUpToFourCards(width: Double, expected: Int) {
        #expect(MobileCardLayout.columns(width: width, accessibilitySize: false, compact: true) == expected)
    }

    @Test func standardColumnsAndAccessibilityKeepTheirExistingBehavior() {
        #expect(MobileCardLayout.columns(width: 361, accessibilitySize: false) == 1)
        #expect(MobileCardLayout.columns(width: 736, accessibilitySize: false) == 2)
        #expect(MobileCardLayout.columns(width: 992, accessibilitySize: false) == 3)
        for compact in [false, true] {
            #expect(MobileCardLayout.columns(width: 992, accessibilitySize: true, compact: compact) == 1)
        }
        #expect(
            MobileCardLayout.columns(
                width: 361, accessibilitySize: false, compact: true, compactWidth: 104) == 3)
        #expect(
            MobileCardLayout.columns(
                width: 288, accessibilitySize: false, compact: true, compactWidth: 104) == 2)
    }

    @Test(arguments: [76.0, 81.25, 104.0, 180.0])
    func compactCardsAreSquareOrTallerRegardlessOfTitleLength(width: Double) {
        let short = measure(compactCard(title: "Gateway"), width: width)
        let long = measure(
            compactCard(title: "Production gateway with a very long name that must be truncated"), width: width)
        #expect(abs(short.width - width) < 0.5)
        #expect(short.height >= width)
        #expect(abs(long.height - short.height) < 0.5)
        #expect(long.height < width + 24)
    }

    @Test(arguments: ["Gateway", "网关"])
    func regularNamesStayOnOneLineWithoutReservingExtraSpace(title: String) {
        func content(_ title: String) -> some View {
            MobileCompactCardContent(title: title) {
                MobileCardIcon(symbol: "server.rack")
            }
            .environment(\.dynamicTypeSize, .large)
        }
        let singleLine = measure(content(title), width: 180)
        let long = measure(content(String(repeating: "\(title) ", count: 12)), width: 180)
        let newline = measure(content("\(title)\n\(title)"), width: 180)
        #expect(abs(long.height - singleLine.height) < 0.5)
        #expect(abs(newline.height - singleLine.height) < 0.5)
    }

    @Test func squareMinimumDoesNotClipTallContent() {
        let size = measure(
            MobileCompactCardLayout { Color.clear.frame(height: 280) }, width: 120)
        #expect(abs(size.width - 120) < 0.5)
        #expect(abs(size.height - 280) < 0.5)
    }

    @Test func accessibilityTextCanGrowPastTwoLinesWithoutShrinking() {
        let title = "Production gateway with an unusually long name for accessible navigation"
        let regular = measure(compactCard(title: title), width: 200)
        let accessible = measure(
            compactCard(title: title).environment(\.dynamicTypeSize, .accessibility3), width: 200)
        #expect(accessible.height > regular.height)
        #expect(accessible.height > accessible.width)
    }

    @Test(.requiresKeyWindow) func compactPreferenceUpdatesMountedCardsAndSurvivesRecreation() async throws {
        let suiteName = "MobileCompactCardTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var widths: [CGFloat] = []
        var standardWidths: [CGFloat] = []
        let controller = UIHostingController(
            rootView: PreferenceFixture(
                widthChanged: { widths.append($0) }, standardWidthChanged: { standardWidths.append($0) }
            )
            .defaultAppStorage(defaults)
            .environment(\.dynamicTypeSize, .large)
            .frame(width: 361))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        await settle(controller)
        #expect(try #require(widths.last) > 300)

        defaults.set(true, forKey: "mobile.compactCards")
        await settle(controller)
        let compactWidth = try #require(widths.last)
        #expect(abs(compactWidth - (361 - 3 * 12) / 4) < 0.5)
        #expect(try #require(standardWidths.last) > 300)

        var restoredWidths: [CGFloat] = []
        let restoredDefaults = try #require(UserDefaults(suiteName: suiteName))
        let restored = UIHostingController(
            rootView: PreferenceFixture(widthChanged: { restoredWidths.append($0) })
                .defaultAppStorage(restoredDefaults)
                .environment(\.dynamicTypeSize, .large)
                .frame(width: 361))
        window.rootViewController = restored
        await settle(restored)
        #expect(abs(try #require(restoredWidths.last) - compactWidth) < 0.5)

        restoredDefaults.set(false, forKey: "mobile.compactCards")
        await settle(restored)
        #expect(try #require(restoredWidths.last) > 300)
    }

    @Test func missingCredentialsRemainVisibleAsCompactWarnings() throws {
        let app = try MobileAppModel(inMemory: true)
        let missingKey = SSHKeyRef(
            label: "Unavailable key", algorithm: .ed25519, credentialRef: "missing.\(UUID())")
        try app.credentials.upsert(missingKey)
        let keyCard = MobileKeyCredentialCard(key: missingKey, credentials: app.credentials, compact: true)
        #expect(keyCard.compactWarnings.contains(AppStrings.Keychain.privateKeyMissing))

        let identity = Identity(name: "", username: "deploy", keyID: UUID())
        let identityCard = MobileIdentityCredentialCard(
            identity: identity, credentials: app.credentials, compact: true)
        #expect(identityCard.compactWarnings.contains(AppStrings.Keychain.keyMissing))
        let empty = MobileIdentityCredentialCard(
            identity: Identity(name: "Draft", username: "deploy"), credentials: app.credentials, compact: true)
        #expect(empty.compactWarnings == [AppStrings.Keychain.noSecret])
    }

    @Test func forwardingBadgesDistinguishIdleProgressSuccessAndFailure() {
        let rule = PortForwardingRule(hostID: UUID())
        func badge(_ runtime: PortForwardingRuntimeState) -> MobileCompactCardBadge? {
            MobileForwardingCardContent(rule: rule, hostName: "Gateway", runtime: runtime, compact: true).compactBadge
        }
        #expect(badge(.stopped) == nil)
        #expect(badge(.connecting)?.symbol == "clock.fill")
        #expect(badge(.awaitingAuthentication)?.symbol == "clock.fill")
        #expect(badge(.running(activeConnections: 1))?.symbol == "checkmark.circle.fill")
        #expect(badge(.failed("Unavailable"))?.symbol == "exclamationmark.triangle.fill")
    }

    @Test func compactSnippetsRetainTheExistingRiskClassification() {
        let safe = MobileCompactSnippetCardContent(snippet: Snippet(title: "Inspect", body: "pwd"))
        let destructive = MobileCompactSnippetCardContent(snippet: Snippet(title: "Delete", body: "rm -rf /"))
        #expect(safe.riskTitle == AppStrings.Snippets.readOnlyRisk)
        #expect(destructive.riskTitle == AppStrings.Snippets.destructiveRisk)
    }

    @Test(arguments: [
        ("en", "Compact"), ("zh-Hans", "紧凑"), ("zh-Hant", "緊湊"),
        ("ja", "コンパクト"), ("ko", "컴팩트"), ("de", "Kompakt"), ("fr", "Compact"),
    ])
    func appearanceSwitchDoesNotUseTheContextCompressionTranslation(language: String, expected: String) {
        #expect(
            AppLocalization.resolve(AppStrings.Settings.compactCards, locale: Locale(identifier: language)) == expected)
    }

    private func compactCard(title: String) -> some View {
        MobileActionCard(compact: true) {
        } content: {
            MobileCompactCardContent(title: title) {
                MobileCardIcon(symbol: "server.rack")
            }
        } actions: {
            EmptyView()
        }
    }

    private func measure(_ view: some View, width: CGFloat) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 10_000))
    }

    private func settle(_ controller: UIHostingController<some View>) async {
        for _ in 0..<8 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private struct PreferenceFixture: View {
        @AppStorage("mobile.compactCards") private var compact = false
        let widthChanged: (CGFloat) -> Void
        var standardWidthChanged: (CGFloat) -> Void = { _ in }

        var body: some View {
            VStack {
                MobileCardGrid(compact: compact) {
                    ForEach(0..<4) { index in
                        MobileActionCard(compact: compact) {
                        } content: {
                            MobileCompactCardContent(title: "Host \(index)") {
                                MobileCardIcon(symbol: "server.rack")
                            }
                        } actions: {
                            EmptyView()
                        }
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.width
                        } action: {
                            if index == 0 { widthChanged($0) }
                        }
                    }
                }
                MobileCardGrid {
                    MobileCard { Text(verbatim: "Unaffected") }
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.width
                        } action: {
                            standardWidthChanged($0)
                        }
                }
            }
        }
    }
}
