import TermindDomain

@MainActor
public protocol MetricsConfigurationStoring {
    func load() throws -> [MetricsSelection]
    func save(_ selections: [MetricsSelection]) throws
}
