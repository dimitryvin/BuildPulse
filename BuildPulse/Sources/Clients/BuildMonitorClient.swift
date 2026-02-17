import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct BuildMonitorClient: Sendable {
    var events: @Sendable () -> AsyncStream<BuildEvent> = { .finished }
}

extension BuildMonitorClient: DependencyKey {
    static let liveValue = BuildMonitorClient(
        events: {
            AsyncStream { continuation in
                let tracker = BuildTrackerCore()

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
        }
    )
}
