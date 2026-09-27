import Foundation
import TermindApplication
import Testing
import UserNotifications

@testable import TermindInfrastructure

@Suite @MainActor
struct SystemNotificationsTests {
    @Test(arguments: [UNAuthorizationStatus.authorized, .denied, .provisional])
    func configuredAuthorizationDoesNotPromptAgain(status: UNAuthorizationStatus) async {
        let center = Center()
        center.status = status
        let service = SystemNotifications(center: center)
        let result = await service.authorization(request: true)
        #expect(result == (status == .denied ? .denied : .allowed))
        #expect(center.authorizationRequests == 0)
        #expect(center.requests.isEmpty)
    }

    @Test func permissionIsRequestedOnlyExplicitlyAndOnlyWhenUndetermined() async {
        let center = Center()
        center.status = .notDetermined
        let service = SystemNotifications(center: center)
        #expect(await service.authorization() == .notDetermined)
        #expect(center.requestedOptions.isEmpty)
        #expect(await service.authorization(request: true) == .allowed)
        #expect(center.requestedOptions == [.alert, .sound, .badge])
        center.status = .denied
        #expect(await service.authorization(request: true) == .denied)
        #expect(center.authorizationRequests == 1)
    }

    @Test func settingsChangeWhileCheckingAuthorizationPreventsSubmission() async {
        let center = Center()
        let service = SystemNotifications(center: center)
        var current = true
        center.readAuthorization = {
            current = false
            return .authorized
        }
        await service.send(notification()) { current }
        #expect(center.requests.isEmpty)
    }

    @Test(arguments: [false, true])
    func staleOrCancelledDeliveryRemovesPendingAndDeliveredRequests(cancel: Bool) async {
        let center = Center()
        let service = SystemNotifications(center: center)
        var current = true
        center.holdDelivery = true
        let notification = notification()
        let task = Task { await service.send(notification) { current } }
        _ = await center.nextSubmission()
        if cancel { task.cancel() } else { current = false }
        center.finishSubmission()
        await task.value
        #expect(center.removedPending == [notification.id])
        #expect(center.removedDelivered == [notification.id])
    }

    @Test func notificationTargetsRoundTripAndEarlyClicksAreConsumedOnce() async {
        let center = Center()
        let service = SystemNotifications(center: center)
        for target in [NotificationTarget.terminal(UUID()), .assistant(UUID()), .transfers] {
            await service.send(AppNotification(target: target, title: "Title", body: "Body")) { true }
            let request = center.requests.last!
            #expect(SystemNotifications.target(request.content) == target)
            #expect(request.content.title == "Title")
            #expect(request.content.body == "Body")
            #expect(request.content.sound != nil)
        }
        #expect(SystemNotifications.target(UNMutableNotificationContent()) == nil)
        let target = NotificationTarget.assistant(UUID())
        service.receiveResponse(action: UNNotificationDismissActionIdentifier, identifier: "ignored", target: target)
        service.receiveResponse(action: UNNotificationDefaultActionIdentifier, identifier: "clicked", target: target)
        var opened: [NotificationTarget] = []
        service.onOpen = { opened.append($0) }
        service.onOpen = { opened.append($0) }
        #expect(opened == [target])
        #expect(center.removedPending == ["clicked"])
        #expect(center.removedDelivered == ["clicked"])
    }

    @Test func badgeWritesSerializeAndConvergeOnTheLatestCount() async {
        let center = Center()
        center.holdBadge = true
        let service = SystemNotifications(center: center)
        #expect(await center.nextBadge() == 0)
        service.setBadgeCount(3)
        service.setBadgeCount(7)
        center.finishBadge()
        #expect(await center.nextBadge() == 7)
        service.setBadgeCount(-1)
        center.finishBadge()
        #expect(await center.nextBadge() == 0)
        center.finishBadge()
        #expect(center.badges == [0, 7, 0])
        #expect(center.maximumConcurrentBadgeWrites == 1)
    }

    @Test(arguments: [
        (UNNotificationDefaultActionIdentifier, true),
        (UNNotificationDismissActionIdentifier, true),
        (UNNotificationDefaultActionIdentifier, false),
    ])
    func backgroundResponseCompletesOnMainThreadAfterRouting(action: String, hasTarget: Bool) async {
        let center = Center()
        let service = SystemNotifications(center: center)
        let target = NotificationTarget.assistant(UUID())
        var opened: [NotificationTarget] = []
        service.onOpen = {
            #expect(Thread.isMainThread)
            opened.append($0)
        }

        let completedOnMainThread = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                #expect(!Thread.isMainThread)
                service.receiveResponse(action: action, identifier: "clicked", target: hasTarget ? target : nil) {
                    continuation.resume(returning: Thread.isMainThread)
                }
            }
        }

        #expect(completedOnMainThread)
        let shouldOpen = action == UNNotificationDefaultActionIdentifier && hasTarget
        #expect(opened == (shouldOpen ? [target] : []))
        #expect(center.removedPending == (shouldOpen ? ["clicked"] : []))
        #expect(center.removedDelivered == (shouldOpen ? ["clicked"] : []))
    }

    @Test func backgroundResponseBeforeRouterIsReadyCompletesAndRetainsTheTarget() async {
        let service = SystemNotifications(center: Center())
        let target = NotificationTarget.terminal(UUID())
        let completedOnMainThread = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                service.receiveResponse(
                    action: UNNotificationDefaultActionIdentifier, identifier: "early", target: target
                ) {
                    continuation.resume(returning: Thread.isMainThread)
                }
            }
        }
        #expect(completedOnMainThread)
        var opened: [NotificationTarget] = []
        service.onOpen = { opened.append($0) }
        service.onOpen = { opened.append($0) }
        #expect(opened == [target])
    }

    private func notification() -> AppNotification {
        AppNotification(target: .assistant(UUID()), title: "Title", body: "Body")
    }

    private final class Center: UserNotificationCenterClient {
        weak var delegate: (any UNUserNotificationCenterDelegate)?
        var status = UNAuthorizationStatus.authorized
        var requestedOptions: UNAuthorizationOptions = []
        var authorizationRequests = 0
        var readAuthorization: (() -> UNAuthorizationStatus)?
        var requests: [UNNotificationRequest] = []
        var removedPending: [String] = []
        var removedDelivered: [String] = []
        var badges: [Int] = []
        var holdDelivery = false
        var holdBadge = false
        var maximumConcurrentBadgeWrites = 0
        private var concurrentBadgeWrites = 0
        private var delivery: CheckedContinuation<Void, Never>?
        private var badge: CheckedContinuation<Void, Never>?
        private let submissions = AsyncStream<Void>.makeStream()
        private let badgeWrites = AsyncStream<Int>.makeStream()

        func authorizationStatus() async -> UNAuthorizationStatus { readAuthorization?() ?? status }
        func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
            requestedOptions = options
            authorizationRequests += 1
            status = .authorized
            return true
        }
        func add(_ request: UNNotificationRequest) async throws {
            requests.append(request)
            if holdDelivery {
                await withCheckedContinuation {
                    delivery = $0
                    submissions.continuation.yield(())
                }
            }
        }
        func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
            removedPending.append(contentsOf: identifiers)
        }
        func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
            removedDelivered.append(contentsOf: identifiers)
        }
        func setBadgeCount(_ count: Int) async throws {
            concurrentBadgeWrites += 1
            maximumConcurrentBadgeWrites = max(maximumConcurrentBadgeWrites, concurrentBadgeWrites)
            defer { concurrentBadgeWrites -= 1 }
            badges.append(count)
            if holdBadge {
                await withCheckedContinuation {
                    badge = $0
                    badgeWrites.continuation.yield(count)
                }
            }
        }
        func nextSubmission() async {
            var iterator = submissions.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        func finishSubmission() {
            delivery?.resume()
            delivery = nil
        }
        func nextBadge() async -> Int? {
            var iterator = badgeWrites.stream.makeAsyncIterator()
            return await iterator.next()
        }
        func finishBadge() {
            badge?.resume()
            badge = nil
        }
    }
}
