import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

@Suite @MainActor
struct HostOperationAdmissionTests {
    @Test func expiryBlocksNewSFTPOperationsWithoutCancellingAnAdmittedTransfer() async throws {
        let hosts = (0..<4).map {
            TermindDomain.Host(
                name: "Host \($0)", host: "host\($0).invalid",
                createdAt: Date(timeIntervalSince1970: Double($0)))
        }
        let library = HostLibraryModel(hosts: hosts)
        let raw = AdmissionSFTPChannel()
        let channel = AccessControlledSFTPChannel(
            channel: raw, accessCheck: library.connectionAccessCheck(for: [hosts[3].id]))
        let upload = Task {
            try await channel.uploadFile(
                from: URL(fileURLWithPath: "/test"), to: "/remote", overwrite: false,
                cancellation: TransferCancellationToken(), progress: { _ in })
        }
        for _ in 0..<200 where !(await raw.isUploading) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await raw.isUploading)
        library.hostAccess.entitlement = .free
        await #expect(throws: HostAccessError.lockedHost(hosts[3].id)) {
            try await channel.listDirectory(at: "/")
        }
        #expect(await raw.directoryReads == 0)
        #expect(await raw.disconnections == 0)
        await raw.finishUpload()
        try await upload.value
        #expect(await raw.completedUploads == 1)
        library.hostAccess.entitlement = .purchased(.purchased)
        _ = try await channel.listDirectory(at: "/")
        #expect(await raw.directoryReads == 1)
    }
}

private actor AdmissionSFTPChannel: SFTPChannelProtocol {
    private var upload: CheckedContinuation<Void, Never>?
    var isUploading: Bool { upload != nil }
    var directoryReads = 0
    var disconnections = 0
    var completedUploads = 0

    func finishUpload() {
        upload?.resume()
        upload = nil
    }
    func disconnect() async { disconnections += 1 }
    func homeDirectory() async throws -> String { "/" }
    func listDirectory(at path: String) async throws -> [RemoteFile] {
        directoryReads += 1
        return []
    }
    func attributes(at path: String) async throws -> RemoteFile? { nil }
    func setPermissions(at path: String, to permissions: UInt32) async throws {}
    func createDirectory(at path: String) async throws {}
    func rename(from source: String, to destination: String, overwrite: Bool) async throws {}
    func removeFile(at path: String) async throws {}
    func removeDirectory(at path: String) async throws {}
    func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        await withCheckedContinuation { upload = $0 }
        completedUploads += 1
    }
    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {}
}
