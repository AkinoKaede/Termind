import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TERMIND_MOBILE_UI_TESTS"] == "1"))
@MainActor
struct MobileTerminalBackgroundTests {
    @Test func oscBackgroundFillsSafeAreaWithoutChangingTerminalGeometryOrIdentity() async throws {
        let app = try MobileAppModel(inMemory: true)
        let workspace = MobileWorkspace(
            descriptor: .init(hostID: UUID(), title: "Background", kind: .ssh), hosts: app.library)
        let regions = MobileRegionTestState()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: MobileRegionTestHost(state: regions) {
                MobileWorkspaceView(
                    library: app.library, pro: app.pro, commandGenerator: app.commandGenerator,
                    workspace: workspace, workspaces: [workspace.descriptor], selectWorkspace: { _ in },
                    renameWorkspace: { _ in }, canCloseMultipleWorkspaces: false,
                    openSameDirectory: { _ in }, closeWorkspace: { _ in }, closeOtherWorkspaces: { _ in })
            })
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 40, left: 0, bottom: 40, right: 0)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            workspace.disconnect()
        }
        try await settle(controller)
        let native = try #require(workspace.terminal.attachedPlatformView)
        native.resignFirstResponder()
        try await settle(controller)
        let surface = try #require(workspace.terminal.surface)
        let frame = native.convert(native.bounds, to: controller.view)
        let initial = workspace.terminal.backgroundColor
        guard case .inMemory(let backend) = workspace.terminal.configuration.backend else {
            Issue.record("Expected an in-memory terminal")
            return
        }

        backend.receive("\u{1B}]11;#123456\u{07}")
        backend.waitForPendingOutput()
        try await settle(controller)
        let changed = TerminalColor(red: 0x12, green: 0x34, blue: 0x56)
        #expect(workspace.terminal.backgroundColor == changed)
        try expectSafeArea(in: controller.view, color: changed)
        #expect(native.convert(native.bounds, to: controller.view) == frame)

        // Shrinking the available region models keyboard avoidance; the same
        // native surface must survive both this and a reserved-region change.
        controller.additionalSafeAreaInsets.bottom += 160
        try await settle(controller)
        #expect(native.bounds.height < frame.height)
        regions.regions = [.init(kind: .occlusion, frame: CGRect(x: 0, y: 0, width: 40, height: 40))]
        try await settle(controller)
        #expect(workspace.terminal.attachedPlatformView === native)
        #expect(workspace.terminal.surface === surface)

        backend.receive("\u{1B}]111\u{07}")
        backend.waitForPendingOutput()
        try await settle(controller)
        #expect(workspace.terminal.backgroundColor == initial)
        try expectSafeArea(in: controller.view, color: initial)

        backend.receive("\u{1B}]11;#123456\u{07}")
        backend.waitForPendingOutput()
        try await settle(controller)
        try expectSafeArea(in: controller.view, color: changed)
        workspace.journey.begin(
            host: .init(name: "Connecting", host: "test.invalid"), route: [], purpose: .sshSession, username: "user")
        try await settle(controller)
        let color = try pixel(in: controller.view, y: 5)
        #expect(!matches(color, changed))
        #expect(workspace.terminal.surface === surface)
    }

    private func settle(_ controller: UIViewController) async throws {
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        controller.view.layoutIfNeeded()
    }

    private func expectSafeArea(in view: UIView, color: TerminalColor) throws {
        #expect(matches(try pixel(in: view, y: 5), color))
        #expect(matches(try pixel(in: view, y: view.bounds.height - 5), color))
    }

    private func matches(_ components: [UInt8], _ color: TerminalColor) -> Bool {
        zip(components, [color.red, color.green, color.blue]).allSatisfy { abs(Int($0) - Int($1)) <= 4 }
    }

    private func pixel(in view: UIView, y: CGFloat) throws -> [UInt8] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
        let cropped = try #require(
            image.cgImage?.cropping(to: CGRect(x: view.bounds.midX, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Array(bytes.prefix(3))
    }
}
