nonisolated enum MobileDestination: String, CaseIterable, Identifiable {
    case vault, metrics, workspaces, assistant, settings

    var id: Self { self }
}
