import TermindRemoteInfrastructure

extension MobileMetricsServices {
    static var live: MobileMetricsServices {
        live(coordinator: RemoteConnectionCoordinator())
    }

    static func live(coordinator: RemoteConnectionCoordinator) -> MobileMetricsServices {
        MobileMetricsServices(makeSampler: { coordinator.makeMetricsSampler() })
    }
}
