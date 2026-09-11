import TermindDomain

@MainActor
public protocol MetricsConfigurationStoring {
    func load() -> [MetricsSelection]
    func save(_ selections: [MetricsSelection])
}
