import UIKit

@MainActor
protocol MobileBackgroundTaskManaging: AnyObject {
    func begin(expiration: @escaping @MainActor () -> Void)
    func finish()
}

@MainActor
protocol MobileBackgroundTaskPlatform: AnyObject {
    func begin(expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
    func end(_ task: UIBackgroundTaskIdentifier)
}

@MainActor
private final class UIApplicationBackgroundTaskPlatform: MobileBackgroundTaskPlatform {
    func begin(expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(
            withName: "Finish remote session work", expirationHandler: expiration)
    }

    func end(_ task: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(task)
    }
}

@MainActor
final class MobileBackgroundController: MobileBackgroundTaskManaging {
    private final class Lease {
        var task: UIBackgroundTaskIdentifier = .invalid
        var ended = false
    }

    private let platform: any MobileBackgroundTaskPlatform
    private var lease: Lease?

    init() {
        platform = UIApplicationBackgroundTaskPlatform()
    }

    init(platform: any MobileBackgroundTaskPlatform) {
        self.platform = platform
    }

    func begin(expiration: @escaping @MainActor () -> Void) {
        finish()
        let lease = Lease()
        self.lease = lease
        // UIKit invokes expiration synchronously on the MainActor. Request cancellation and retire the lease
        // before returning; the async drains started by `expiration` remain best effort.
        lease.task = platform.begin { [weak self, weak lease] in
            guard let self, let lease else { return }
            expire(lease, expiration: expiration)
        }

        guard self.lease === lease else {
            retire(lease)
            return
        }
        if lease.task == .invalid {
            expire(lease, expiration: expiration)
        }
    }

    func finish() {
        guard let lease else { return }
        self.lease = nil
        retire(lease)
    }

    private func expire(_ lease: Lease, expiration: @MainActor () -> Void) {
        guard self.lease === lease else { return }
        self.lease = nil
        expiration()
        retire(lease)
    }

    private func retire(_ lease: Lease) {
        guard !lease.ended else { return }
        // Expiration may run during `begin` before UIKit returns the identifier. An invalid task is still pending.
        guard lease.task != .invalid else { return }
        lease.ended = true
        platform.end(lease.task)
    }
}
