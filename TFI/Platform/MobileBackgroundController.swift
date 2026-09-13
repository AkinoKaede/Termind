import UIKit

@MainActor
protocol MobileBackgroundTaskManaging: AnyObject {
    func begin(expiration: @escaping @MainActor () -> Void)
    func finish()
}

@MainActor
final class MobileBackgroundController: MobileBackgroundTaskManaging {
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var expirationID: UUID?

    func begin(expiration: @escaping @MainActor () -> Void) {
        finish()
        let expirationID = UUID()
        self.expirationID = expirationID
        task = UIApplication.shared.beginBackgroundTask(withName: "Finish remote session work") { [weak self] in
            Task { @MainActor in
                guard self?.expirationID == expirationID else { return }
                self?.expirationID = nil
                expiration()
                self?.endTask()
            }
        }
        if task == .invalid, self.expirationID == expirationID {
            self.expirationID = nil
            expiration()
        }
    }

    func finish() {
        expirationID = nil
        endTask()
    }

    private func endTask() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
