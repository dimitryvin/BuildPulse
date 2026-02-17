import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct BuildMonitorClient: Sendable {
    var events: @Sendable () -> AsyncStream<BuildEvent> = { .finished }
    var derivedDataChanges: @Sendable () -> AsyncStream<Void> = { .finished }
}

extension BuildMonitorClient: DependencyKey {
    static let liveValue: BuildMonitorClient = {
        // Shared tracker instance so both streams use the same FSEvents/polling
        nonisolated(unsafe) let tracker = BuildTrackerCore()

        return BuildMonitorClient(
            events: {
                AsyncStream { continuation in
                    tracker.onBuildStarted = { project in
                        continuation.yield(.buildStarted(project: project, startTime: Date()))
                    }

                    tracker.onBuildFinished = { project, duration, succeeded in
                        continuation.yield(.buildFinished(project: project, duration: duration, succeeded: succeeded))
                    }

                    tracker.startMonitoring()

                    continuation.onTermination = { _ in
                        tracker.stopMonitoring()
                    }
                }
            },
            derivedDataChanges: {
                AsyncStream { continuation in
                    tracker.onDerivedDataChanged = {
                        continuation.yield()
                    }

                    continuation.onTermination = { _ in
                        tracker.onDerivedDataChanged = nil
                    }
                }
            }
        )
    }()
}
