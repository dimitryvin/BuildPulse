import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct DerivedDataClient: Sendable {
    var scan: @Sendable () async -> ([DerivedDataProject], Int64) = { ([], 0) }
    var scanIncremental: @Sendable () async -> AsyncStream<([DerivedDataProject], Int64)> = { .finished }
    var delete: @Sendable (DerivedDataProject) async -> Void
    var deleteOlderThan: @Sendable (Int) async -> Int = { _ in 0 }
}

extension DerivedDataClient: DependencyKey {
    static let liveValue: DerivedDataClient = {
        let manager = DerivedDataManager()
        return DerivedDataClient(
            scan: { await manager.scan() },
            scanIncremental: { await manager.scanIncremental() },
            delete: { project in await manager.delete(project: project) },
            deleteOlderThan: { days in await manager.deleteOlderThan(days: days) }
        )
    }()
}
