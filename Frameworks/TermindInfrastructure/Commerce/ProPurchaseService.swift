import TermindDomain

@MainActor
protocol ProPurchaseService: AnyObject {
    var updates: AsyncStream<EntitlementStatus> { get }
    func currentStatus() async throws -> EntitlementStatus
}
