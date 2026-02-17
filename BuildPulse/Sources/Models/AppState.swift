import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var derivedDataProjects: [DerivedDataProject] = []
    @Published var totalDerivedDataSize: Int64 = 0
    @Published var buildRecords: [BuildRecord] = []
    @Published var isScanning = false
    @Published var activeBuild: ActiveBuild?
    @Published var selectedTab: Tab = .overview

    let derivedDataManager = DerivedDataManager()
    let buildTracker = BuildTracker()
    let buildStore = BuildHistoryStore()

    private var cancellables = Set<AnyCancellable>()

    enum Tab: String, CaseIterable {
        case overview = "Overview"
        case derivedData = "Derived Data"
        case builds = "Builds"
    }

    struct ActiveBuild {
        let project: String
        let startTime: Date
        var elapsed: TimeInterval { Date().timeIntervalSince(startTime) }
    }

    var menuBarTitle: String {
        if let build = activeBuild {
            let secs = Int(build.elapsed)
            return "\(secs)s"
        }
        let size = ByteCountFormatter.string(fromByteCount: totalDerivedDataSize, countStyle: .file)
        return size
    }

    init() {
        buildRecords = buildStore.load()
        setupBuildTracking()
        Task { await refreshDerivedData() }
    }

    func refreshDerivedData() async {
        isScanning = true
        let (projects, total) = await derivedDataManager.scan()
        derivedDataProjects = projects
        totalDerivedDataSize = total
        isScanning = false
    }

    func deleteProject(_ project: DerivedDataProject) async {
        await derivedDataManager.delete(project: project)
        await refreshDerivedData()
    }

    func deleteProjects(_ projects: [DerivedDataProject]) async {
        for p in projects {
            await derivedDataManager.delete(project: p)
        }
        await refreshDerivedData()
    }

    func statsFor(range: TimeRange) -> BuildStats {
        let filtered = buildRecords.filter { $0.startTime >= range.startDate }
        guard !filtered.isEmpty else {
            return BuildStats(totalBuilds: 0, avgDuration: 0, totalTime: 0, successRate: 0)
        }
        let total = filtered.reduce(0.0) { $0 + $1.duration }
        let succeeded = filtered.filter { $0.succeeded }.count
        return BuildStats(
            totalBuilds: filtered.count,
            avgDuration: total / Double(filtered.count),
            totalTime: total,
            successRate: Double(succeeded) / Double(filtered.count)
        )
    }

    private func setupBuildTracking() {
        buildTracker.onBuildStarted = { [weak self] project in
            Task { @MainActor in
                self?.activeBuild = ActiveBuild(project: project, startTime: Date())
            }
        }

        buildTracker.onBuildFinished = { [weak self] project, duration, succeeded in
            Task { @MainActor in
                guard let self else { return }
                let record = BuildRecord(
                    scheme: project,
                    project: project,
                    startTime: Date().addingTimeInterval(-duration),
                    duration: duration,
                    succeeded: succeeded
                )
                self.buildRecords.insert(record, at: 0)
                self.buildStore.save(self.buildRecords)
                self.activeBuild = nil
                await self.refreshDerivedData()
            }
        }

        buildTracker.startMonitoring()
    }
}
