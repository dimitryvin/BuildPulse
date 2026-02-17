import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct DerivedDataClient: Sendable {
    var scan: @Sendable () async -> ([DerivedDataProject], Int64) = { ([], 0) }
    var listProjects: @Sendable () async -> (projects: [DerivedDataProject], totalSize: Int64, uncachedIndices: [Int]) = { ([], 0, []) }
    var computeSize: @Sendable (DerivedDataProject) async -> Int64 = { _ in 0 }
    var delete: @Sendable (DerivedDataProject) async -> Void
    var deleteOlderThan: @Sendable (Int) async -> Int = { _ in 0 }
}

extension DerivedDataClient: DependencyKey {
    static let liveValue: DerivedDataClient = {
        let manager = DerivedDataManager()
        return DerivedDataClient(
            scan: { await manager.scan() },
            listProjects: { await manager.listProjects() },
            computeSize: { project in await manager.computeSize(for: project) },
            delete: { project in await manager.delete(project: project) },
            deleteOlderThan: { days in await manager.deleteOlderThan(days: days) }
        )
    }()
}
