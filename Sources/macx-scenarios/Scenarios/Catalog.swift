enum Catalog {
    static let all: [CoreScenario] =
        BrowseScenarios.all + OpsScenarios.all + ConflictScenarios.all + ClipboardScenarios.all + UndoScenarios.all
        + WatcherScenarios.all + CrossVolumeScenarios.all + CrashScenarios.all

    static func select(_ filter: String?) -> [CoreScenario] {
        guard let filter, !filter.isEmpty else { return all }
        return all.filter { $0.name.contains(filter) }
    }
}
