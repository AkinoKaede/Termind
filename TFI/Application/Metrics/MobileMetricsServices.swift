import TermindApplication

struct MobileMetricsServices {
    let makeSampler: @Sendable () -> any MetricsSampling

    static var testing: MobileMetricsServices {
        MobileMetricsServices(makeSampler: { preconditionFailure("Tests must not start live Metrics sampling") })
    }
}
