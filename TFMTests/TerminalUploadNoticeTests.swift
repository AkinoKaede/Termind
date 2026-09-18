import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite(.enabled(if: ProcessInfo.processInfo.environment["TERMIND_SSH_FIXTURE"] != nil), .serialized)
@MainActor
struct TerminalUploadNoticeTests {
    @Test(arguments: ["kbd", "none"])
    func uploadFailureKeepsTerminalFocusAndDismissesWithoutAnAlert(_ mode: String) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["TERMIND_SSH_FIXTURE"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let identity = Identity(name: "Upload fixture", username: mode)
        let host = TermindDomain.Host(
            name: "Upload fixture", host: "127.0.0.1", port: fixture.port, identityID: identity.id)
        let library = HostLibraryModel(
            hosts: [host], identities: [identity],
            knownHosts: [
                KnownHostEntry(
                    hostname: host.host, port: host.port, algorithm: .rsa, fingerprint: fixture.hostFingerprint)
            ])
        let app = AppModel(hosts: library)
        let session = SSHSessionModel(host: host)
        let workspace = Workspace(pane: Pane(.sshSession(session)))
        let windowModel = WindowModel(workspaces: [workspace])
        defer {
            session.disconnect()
            app.shutdownForTermination()
        }
        session.connect(using: library)
        if mode == "kbd" {
            try await waitUntil { session.connection.keyboardAuthentication.current != nil }
            let challenge = try #require(session.connection.keyboardAuthentication.current)
            session.connection.keyboardAuthentication.respond(challenge.id, answers: ["123456"])
        }
        try await waitUntil { session.status == .connected && !session.connectionJourney.isPresented }
        session.receiveShellIntegrationEvent(.homeResolutionUnavailable)
        session.workingDirectory = "/"

        let drop = UploadDropState()
        let controller = NSHostingController(
            rootView: UploadHarness(session: session, workspace: workspace, drop: drop)
                .frame(width: 720, height: 420)
                .environment(app).environment(windowModel))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(300))
        let responder = try #require(window.firstResponder)
        let before = try noticeRegion(controller.view)
        drop.request = LocalFileDropRequest(urls: [
            FileManager.default.temporaryDirectory.appending(path: "missing-upload-\(UUID())")
        ])
        try await Task.sleep(for: .milliseconds(700))
        // The native terminal owns accessibility, so inspect the otherwise empty lower region.
        #expect(try noticeRegion(controller.view) != before)
        #expect(window.sheets.isEmpty)
        #expect(window.firstResponder === responder)
        #expect(session.connection.keyboardAuthentication.current == nil)
        #expect(app.sftpTransfers.sftpTransfers.isEmpty)

        controller.view.layoutSubtreeIfNeeded()
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let image = try #require(bitmap.representation(using: .png, properties: [:]))
        let name = "terminal-upload-\(mode)-\(Locale.current.identifier)"
        Attachment.record(image, named: "\(name).png")
        try image.write(to: FileManager.default.temporaryDirectory.appending(path: "\(name).png"))
        try await Task.sleep(for: .milliseconds(1500))
        #expect(try noticeRegion(controller.view) != before)
        try await waitUntil { (try? noticeRegion(controller.view)) == before }
        #expect(window.firstResponder === responder)
    }

    private func noticeRegion(_ view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        let region = CGRect(x: 0, y: view.isFlipped ? view.bounds.height - 180 : 0, width: 720, height: 180)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: region))
        view.cacheDisplay(in: region, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition())
    }

    private struct Fixture: Decodable {
        let port: Int
        let hostFingerprint: String
    }
}

@MainActor @Observable
private final class UploadDropState {
    var request: LocalFileDropRequest?
}

private struct UploadHarness: View {
    let session: SSHSessionModel
    let workspace: Workspace
    let drop: UploadDropState

    var body: some View {
        TerminalPlaceholderView(
            sshSession: session, workspace: workspace, isVisible: true, requestsFocus: true,
            externalFileDrop: drop.request, closePane: {})
    }
}
