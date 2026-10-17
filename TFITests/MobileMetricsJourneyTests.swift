import SwiftUI
import TermindApplication
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@Suite(.requiresKeyWindow, .serialized) @MainActor
struct MobileMetricsJourneyTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func authenticationStaysInMetricsAcrossNavigationAndSizeChanges(_ language: String) async throws {
        let sampler = MobileJourneyMetricsSampler()
        let app = try MobileAppModel(dependencies: .testing(metrics: MobileMetricsServices(makeSampler: { sampler })))
        let identity = Identity(name: "Deploy", username: "deploy")
        let host = TermindDomain.Host(
            name: "Production Gateway", host: "gateway.example.invalid", identityID: identity.id)
        try app.library.upsert(identity, passwordUpdate: .replace("test-only"))
        app.library.upsert(host)
        let scene = MobileSceneModel(app: app, sessionID: "test")
        scene.selectedDestination = .metrics
        #expect(app.metrics.add(host.id))
        let server = try #require(app.metrics.servers.first)
        let route = MetricsJourneyTestRoute()
        var features = MobileFeatureRegistry()
        features.register(
            MobileFeatureRegistration(id: .metrics, title: "Metrics", symbol: "waveform.path.ecg") { app, _ in
                AnyView(
                    Text("Metrics")
                        .navigationTitle("Metrics")
                        .navigationDestination(
                            isPresented: Binding(get: { route.showsDetails }, set: { route.showsDetails = $0 })
                        ) { MobileMetricsDetailView(app: app, server: server) })
            })
        let windowScene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = windowScene.keyWindow
        let window = UIWindow(windowScene: windowScene)
        let container = UIViewController()
        let controller = UIHostingController(
            rootView: MobileRootView(app: app, scene: scene, features: features)
                .environment(\.locale, Locale(identifier: language))
                .environment(\.scenePhase, .active))
        container.addChild(controller)
        container.view.addSubview(controller.view)
        controller.didMove(toParent: container)
        window.rootViewController = container
        window.windowLevel = .alert + 3
        window.makeKeyAndVisible()
        defer {
            app.metrics.core.shutdown()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        resize(controller, width: 430)
        try await wait { server.keyboardAuthentication.current != nil }
        let challenge = try #require(server.keyboardAuthentication.current)
        #expect(!route.showsDetails)
        route.showsDetails = true
        for width in [430.0, 600.0, 1024.0] {
            resize(controller, width: width)
            try await Task.sleep(for: .milliseconds(500))
            let fields = descendants(UITextField.self, in: controller.view)
            #expect(fields.count == 2)
            #expect(fields.filter(\.isSecureTextEntry).count == 1)
            #expect(descendants(UISegmentedControl.self, in: controller.view).isEmpty)
            #expect(presented(in: controller) == nil)
            #expect(server.keyboardAuthentication.current?.id == challenge.id)
            try capture(controller.view, name: "metrics-journey-\(language)-\(Int(width))")
        }
        route.showsDetails = false
        try await Task.sleep(for: .milliseconds(400))
        #expect(server.keyboardAuthentication.current?.id == challenge.id)
        route.showsDetails = true
        resize(controller, width: 430)
        // Native traits exercise large text without replacing the feature navigation.
        controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        try await Task.sleep(for: .milliseconds(500))
        #expect(descendants(UITextField.self, in: controller.view).count == 2)
        try capture(controller.view, name: "metrics-journey-\(language)-large-type")
        #expect(await sampler.connections == 1)
        controller.traitOverrides.preferredContentSizeCategory = .large
        let fields = descendants(UITextField.self, in: controller.view)
        let account = try #require(fields.first { !$0.isSecureTextEntry })
        let code = try #require(fields.first { $0.isSecureTextEntry })
        account.text = "deploy"
        account.sendActions(for: .editingChanged)
        code.text = "test-code"
        code.sendActions(for: .editingChanged)
        #expect(code.becomeFirstResponder())
        code.sendActions(for: .editingDidEndOnExit)
        try await wait { server.point != nil && !server.showsConnectionJourney }
        try await Task.sleep(for: .milliseconds(400))
        #expect(descendants(UITextField.self, in: controller.view).isEmpty)
        #expect(presented(in: controller) == nil)
        #expect(await sampler.answers == ["deploy", "test-code"])
        #expect(await sampler.connections == 1)
        try capture(controller.view, name: "metrics-journey-\(language)-live")
    }

    private func wait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    private func resize(_ controller: UIViewController, width: CGFloat) {
        let frame = CGRect(x: 0, y: 0, width: width, height: 900)
        controller.view.window?.frame = frame
        controller.parent?.view.frame = frame
        controller.traitOverrides.horizontalSizeClass = width >= 600 ? .regular : .compact
        controller.view.frame = frame
        controller.view.setNeedsLayout()
    }

    private func capture(_ view: UIView, name: String) throws {
        let data = UIGraphicsImageRenderer(bounds: view.bounds).pngData { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        Attachment.record(data, named: "\(device)-\(name).png")
        let directory = FileManager.default.temporaryDirectory.appending(path: "termind-metrics-journey")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "\(device)-\(name).png"))
        print("Metrics Journey snapshot: \(directory.path)/\(device)-\(name).png")
    }
}

@Observable @MainActor private final class MetricsJourneyTestRoute {
    var showsDetails = false
}

private actor MobileJourneyMetricsSampler: MetricsSampling {
    var connections = 0
    var answers: [String] = []
    func connect(_ configuration: SSHConnectionConfiguration) async throws { throw CancellationError() }
    func connect(_ request: SSHConnectionRequest) async throws {
        connections += 1
        let handler = try #require(request.keyboardInteractive)
        answers = try await handler(
            SSHKeyboardInteractiveChallenge(
                connectionID: UUID(), hostID: request.configuration.hostID,
                hostname: request.configuration.host, port: request.configuration.port,
                username: request.configuration.username, round: 1, name: "PAM",
                instruction: "Enter your account and verification code.",
                prompts: [.init(text: "Account", echo: true), .init(text: "Verification code", echo: false)]))
    }
    func sample() async throws -> MetricsSample {
        .init(uptime: 1, cpu: [10, 0, 10, 80], memoryUsed: 50, memoryTotal: 100)
    }
    func gpu() async throws -> NvidiaSnapshot? { nil }
    func disconnect() async {}
}
