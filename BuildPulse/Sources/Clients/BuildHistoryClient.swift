import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct BuildHistoryClient: Sendable {
    var load: @Sendable () async -> [BuildRecord] = { [] }
    var save: @Sendable ([BuildRecord]) async -> Void
}

extension BuildHistoryClient: DependencyKey {
    static let liveValue: BuildHistoryClient = {
        let store = BuildHistoryStore()
        return BuildHistoryClient(
            load: { store.load() },
            save: { records in store.save(records) }
        )
    }()
}
