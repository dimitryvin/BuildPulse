import AppKit
import ComposableArchitecture
import Foundation
import UserNotifications

@Reducer
struct AppFeature {

    // MARK: - State

    @ObservableState
    struct State {
        // Shared across tabs
        var activeBuild: ActiveBuild? = nil
        var buildRecords: [BuildRecord] = []
        var derivedDataProjects: [DerivedDataProject] = []
        var isScanning = false
        var selectedTab: Tab = .overview
        var totalDerivedDataSize: Int64 = 0

        // Tab-local
        var overviewSelectedRange: TimeRange = .today
        var buildsSelectedRange: TimeRange = .week
        var derivedDataSortOrder: SortOrder = .size
        var derivedDataSelection: Set<String> = []

        // Internal tracking
        var hasAppeared = false
        var hasRunAutoCleanup = false

        // Settings via @Shared (UserDefaults-backed)
        @Shared(.appStorage("alertThresholdGB")) var alertThresholdGB = 50.0
        @Shared(.appStorage("autoDeleteDays")) var autoDeleteDays = 0
        @Shared(.appStorage("launchAtLogin")) var launchAtLogin = false
        @Shared(.appStorage("showSizeInMenuBar")) var showSizeInMenuBar = true
        @Shared(.appStorage("notifyOnBuildComplete")) var notifyOnBuildComplete = false

        // Presentation
        @Presents var alert: AlertState<Action.Alert>?

        // Computed
        var menuBarTitle: String {
            if let build = activeBuild {
                return "\(build.elapsedSeconds)s"
            }
            if showSizeInMenuBar && totalDerivedDataSize > 0 {
                return ByteCountFormatter.string(fromByteCount: totalDerivedDataSize, countStyle: .file)
            }
            return ""
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

        var sortedProjects: [DerivedDataProject] {
            switch derivedDataSortOrder {
            case .size:
                return derivedDataProjects.sorted { $0.sizeBytes > $1.sizeBytes }
            case .name:
                return derivedDataProjects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            case .modified:
                return derivedDataProjects.sorted { $0.lastModified > $1.lastModified }
            }
        }
    }

    enum SortOrder: String, CaseIterable, Equatable, Sendable {
        case size = "Size"
        case name = "Name"
        case modified = "Last Modified"
    }

    // MARK: - Actions

    enum Action: Equatable {
        // Lifecycle
        case onAppear

        // Tab
        case tabSelected(Tab)

        // Build monitoring
        case buildEvent(BuildEvent)
        case timerTicked

        // Derived data
        case refreshDerivedData
        case derivedDataScanned([DerivedDataProject], Int64)

        // Persistence
        case buildRecordsLoaded([BuildRecord])
        case clearBuildHistory

        // Overview
        case overviewRangeChanged(TimeRange)

        // Builds tab
        case buildsRangeChanged(TimeRange)

        // Derived data tab
        case sortOrderChanged(SortOrder)
        case toggleProjectSelection(String)
        case deleteProjectTapped(DerivedDataProject)
        case deleteSelectedTapped
        case deleteOlderThan(days: Int)
        case deleteAllTapped
        case projectsDeleted

        // Alert
        case alert(PresentationAction<Alert>)

        // Settings
        case quitButtonTapped

        @CasePathable
        enum Alert: Equatable {
            case confirmDeleteProject(DerivedDataProject)
            case confirmDeleteSelected
            case confirmDeleteAll
        }
    }

    // MARK: - Dependencies

    @Dependency(BuildMonitorClient.self) var buildMonitor
    @Dependency(DerivedDataClient.self) var derivedDataClient
    @Dependency(BuildHistoryClient.self) var buildHistoryClient
    @Dependency(\.continuousClock) var clock

    private enum CancelID {
        case buildTimer
        case buildMonitor
    }

    // MARK: - Reducer

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {

            // MARK: Lifecycle

            case .onAppear:
                guard !state.hasAppeared else { return .none }
                state.hasAppeared = true
                return .merge(
                    // Subscribe to build events
                    .run { send in
                        for await event in buildMonitor.events() {
                            await send(.buildEvent(event))
                        }
                    }
                    .cancellable(id: CancelID.buildMonitor),

                    // Load build history
                    .run { send in
                        let records = await buildHistoryClient.load()
                        await send(.buildRecordsLoaded(records))
                    },

                    // Initial scan
                    .send(.refreshDerivedData)
                )

            // MARK: Tab

            case let .tabSelected(tab):
                state.selectedTab = tab
                return .none

            // MARK: Build Monitoring

            case let .buildEvent(.buildStarted(project, startTime)):
                state.activeBuild = ActiveBuild(project: project, startTime: startTime)
                return .run { send in
                    for await _ in clock.timer(interval: .seconds(1)) {
                        await send(.timerTicked)
                    }
                }
                .cancellable(id: CancelID.buildTimer, cancelInFlight: true)

            case let .buildEvent(.buildFinished(project, duration, succeeded)):
                let startTime = state.activeBuild?.startTime ?? Date().addingTimeInterval(-duration)
                let record = BuildRecord(
                    scheme: project,
                    project: project,
                    startTime: startTime,
                    duration: duration,
                    succeeded: succeeded
                )
                state.buildRecords.insert(record, at: 0)
                state.activeBuild = nil

                let records = state.buildRecords
                let shouldNotify = state.notifyOnBuildComplete

                return .merge(
                    .cancel(id: CancelID.buildTimer),
                    .run { _ in
                        await buildHistoryClient.save(records)
                    },
                    .send(.refreshDerivedData),
                    shouldNotify ? .run { _ in
                        let content = UNMutableNotificationContent()
                        content.title = "Build \(succeeded ? "Succeeded" : "Failed")"
                        content.body = "\(project) - \(BuildRecord.formatDuration(duration))"
                        content.sound = .default
                        let request = UNNotificationRequest(
                            identifier: UUID().uuidString,
                            content: content,
                            trigger: nil
                        )
                        try? await UNUserNotificationCenter.current().add(request)
                    } : .none
                )

            case .timerTicked:
                if state.activeBuild != nil {
                    state.activeBuild?.elapsedSeconds += 1
                }
                return .none

            // MARK: Derived Data

            case .refreshDerivedData:
                state.isScanning = true
                return .run { send in
                    let (projects, total) = await derivedDataClient.scan()
                    await send(.derivedDataScanned(projects, total))
                }

            case let .derivedDataScanned(projects, total):
                state.isScanning = false
                state.derivedDataProjects = projects
                state.totalDerivedDataSize = total

                // Auto-cleanup: run once on first scan
                let autoDeleteDays = state.autoDeleteDays
                if autoDeleteDays > 0 && !state.hasRunAutoCleanup {
                    state.hasRunAutoCleanup = true
                    return .run { send in
                        let _ = await derivedDataClient.deleteOlderThan(autoDeleteDays)
                        await send(.refreshDerivedData)
                    }
                }

                // Check threshold alert
                let currentGB = Double(total) / 1_073_741_824.0
                let threshold = state.alertThresholdGB
                if currentGB > threshold && threshold > 0 {
                    return .run { _ in
                        let content = UNMutableNotificationContent()
                        content.title = "DerivedData Alert"
                        content.body = String(format: "DerivedData is %.1f GB (threshold: %.0f GB)", currentGB, threshold)
                        content.sound = .default
                        let request = UNNotificationRequest(
                            identifier: "derived-data-alert",
                            content: content,
                            trigger: nil
                        )
                        try? await UNUserNotificationCenter.current().add(request)
                    }
                }

                return .none

            // MARK: Persistence

            case let .buildRecordsLoaded(records):
                state.buildRecords = records
                return .none

            case .clearBuildHistory:
                state.buildRecords = []
                return .run { _ in
                    await buildHistoryClient.save([])
                }

            // MARK: Overview

            case let .overviewRangeChanged(range):
                state.overviewSelectedRange = range
                return .none

            // MARK: Builds

            case let .buildsRangeChanged(range):
                state.buildsSelectedRange = range
                return .none

            // MARK: Derived Data Tab

            case let .sortOrderChanged(order):
                state.derivedDataSortOrder = order
                return .none

            case let .toggleProjectSelection(id):
                if state.derivedDataSelection.contains(id) {
                    state.derivedDataSelection.remove(id)
                } else {
                    state.derivedDataSelection.insert(id)
                }
                return .none

            case let .deleteProjectTapped(project):
                state.alert = AlertState {
                    TextState("Delete Derived Data?")
                } actions: {
                    ButtonState(role: .cancel) { TextState("Cancel") }
                    ButtonState(role: .destructive, action: .confirmDeleteProject(project)) {
                        TextState("Delete")
                    }
                } message: {
                    TextState("Remove \(project.name) (\(project.sizeFormatted))? Xcode will rebuild on next build.")
                }
                return .none

            case .deleteSelectedTapped:
                let count = state.derivedDataSelection.count
                state.alert = AlertState {
                    TextState("Delete Derived Data?")
                } actions: {
                    ButtonState(role: .cancel) { TextState("Cancel") }
                    ButtonState(role: .destructive, action: .confirmDeleteSelected) {
                        TextState("Delete")
                    }
                } message: {
                    TextState("Remove \(count) projects? Xcode will rebuild them on next build.")
                }
                return .none

            case let .deleteOlderThan(days):
                return .run { send in
                    let _ = await derivedDataClient.deleteOlderThan(days)
                    await send(.projectsDeleted)
                }

            case .deleteAllTapped:
                state.alert = AlertState {
                    TextState("Delete All Derived Data?")
                } actions: {
                    ButtonState(role: .cancel) { TextState("Cancel") }
                    ButtonState(role: .destructive, action: .confirmDeleteAll) {
                        TextState("Delete")
                    }
                } message: {
                    TextState("Remove all projects? Xcode will rebuild everything on next build.")
                }
                return .none

            case .projectsDeleted:
                state.derivedDataSelection.removeAll()
                return .send(.refreshDerivedData)

            // MARK: Alert

            case let .alert(.presented(.confirmDeleteProject(project))):
                return .run { send in
                    await derivedDataClient.delete(project)
                    await send(.projectsDeleted)
                }

            case .alert(.presented(.confirmDeleteSelected)):
                let selectedIDs = state.derivedDataSelection
                let toDelete = state.derivedDataProjects.filter { selectedIDs.contains($0.id) }
                return .run { send in
                    for project in toDelete {
                        await derivedDataClient.delete(project)
                    }
                    await send(.projectsDeleted)
                }

            case .alert(.presented(.confirmDeleteAll)):
                let all = state.derivedDataProjects
                return .run { send in
                    for project in all {
                        await derivedDataClient.delete(project)
                    }
                    await send(.projectsDeleted)
                }

            case .alert(.dismiss):
                return .none

            // MARK: Settings

            case .quitButtonTapped:
                NSApplication.shared.terminate(nil)
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }
}

// MARK: - Helpers

extension BuildRecord {
    static func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}
