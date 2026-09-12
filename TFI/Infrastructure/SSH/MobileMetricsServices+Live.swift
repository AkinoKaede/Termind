import TermindRemoteInfrastructure

extension MobileMetricsServices {
    static var live: MobileMetricsServices {
        MobileMetricsServices(makeSampler: { SSHMetricsSampler(session: SSHExecSession()) })
    }
}
