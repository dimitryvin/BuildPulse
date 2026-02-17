import Foundation
import CoreServices

final class BuildTracker {
    var onBuildStarted: ((String) -> Void)?
    var onBuildFinished: ((String, TimeInterval, Bool) -> Void)?

    private var eventStream: FSEventStreamRef?
    private var activeBuildProject: String?
    private var buildStartTime: Date?
    private var buildCheckTimer: Timer?

    private let derivedDataPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Developer/Xcode/DerivedData"
    }()

    private let logPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Developer/Xcode/DerivedData/Logs"
    }()

    func startMonitoring() {
        startFSEvents()
        startXcodeBuildPolling()
    }

    func stopMonitoring() {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }
        buildCheckTimer?.invalidate()
    }

    // MARK: - Xcode Build Log Polling

    private func startXcodeBuildPolling() {
        // Poll for active xcodebuild processes
        buildCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkForActiveBuilds()
        }
    }

    private func checkForActiveBuilds() {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-lf", "xcodebuild"]
        process.standardOutput = pipe
        process.standardError = Pipe()

        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let isBuilding = !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && output.contains("xcodebuild")

        if isBuilding && activeBuildProject == nil {
            // Build started
            let project = extractProjectFromProcessList(output)
            activeBuildProject = project
            buildStartTime = Date()
            onBuildStarted?(project)
        } else if !isBuilding && activeBuildProject != nil {
            // Build finished
            let duration = Date().timeIntervalSince(buildStartTime ?? Date())
            let project = activeBuildProject ?? "Unknown"
            activeBuildProject = nil
            buildStartTime = nil
            // Check build result from recent log
            let succeeded = checkLastBuildResult(project: project)
            onBuildFinished?(project, duration, succeeded)
        }
    }

    private func extractProjectFromProcessList(_ output: String) -> String {
        // Try to find project name from xcodebuild args
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            if let range = line.range(of: "-project ") {
                let after = line[range.upperBound...]
                let projectFile = after.components(separatedBy: " ").first ?? ""
                return projectFile
                    .replacingOccurrences(of: ".xcodeproj", with: "")
                    .components(separatedBy: "/").last ?? "Unknown"
            }
            if let range = line.range(of: "-scheme ") {
                let after = line[range.upperBound...]
                return String(after.components(separatedBy: " ").first ?? "Unknown")
            }
        }
        return "Xcode Build"
    }

    private func checkLastBuildResult(project: String) -> Bool {
        // Check the Xcode build result from the most recent log
        let fm = FileManager.default
        let ddPath = URL(fileURLWithPath: derivedDataPath)

        guard let contents = try? fm.contentsOfDirectory(
            at: ddPath,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return true }

        // Find the most recently modified project folder
        let sorted = contents
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let date = values.contentModificationDate else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }

        guard let mostRecent = sorted.first else { return true }

        let logsDir = mostRecent.0.appendingPathComponent("Logs/Build")
        guard let logFiles = try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) else {
            return true
        }

        // Look for .xcactivitylog files
        let activityLogs = logFiles.filter { $0.pathExtension == "xcactivitylog" }
            .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }

        // If recent log exists, assume success (detailed parsing would need gzip decompression)
        return !activityLogs.isEmpty
    }

    // MARK: - FSEvents

    private func startFSEvents() {
        let pathsToWatch = [derivedDataPath] as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            // FSEvents callback - primarily used to trigger UI refresh
            // Build detection is handled by process polling above
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        eventStream = stream
    }
}
