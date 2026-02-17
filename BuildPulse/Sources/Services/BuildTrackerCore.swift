import Foundation
import CoreServices

final class BuildTrackerCore: @unchecked Sendable {
    var onBuildStarted: (@Sendable (String) -> Void)?
    var onBuildFinished: (@Sendable (String, TimeInterval, Bool) -> Void)?

    private var eventStream: FSEventStreamRef?
    private var activeBuildProject: String?
    private var buildStartTime: Date?
    private var buildCheckTimer: Timer?
    private let lock = NSLock()

    private let derivedDataPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Developer/Xcode/DerivedData"
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
        buildCheckTimer = nil
    }

    // MARK: - Xcode Build Log Polling

    private func startXcodeBuildPolling() {
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

        lock.lock()
        if isBuilding && activeBuildProject == nil {
            let project = extractProjectFromProcessList(output)
            activeBuildProject = project
            buildStartTime = Date()
            lock.unlock()
            onBuildStarted?(project)
        } else if !isBuilding && activeBuildProject != nil {
            let duration = Date().timeIntervalSince(buildStartTime ?? Date())
            let project = activeBuildProject ?? "Unknown"
            activeBuildProject = nil
            buildStartTime = nil
            lock.unlock()
            let succeeded = checkLastBuildResult(project: project)
            onBuildFinished?(project, duration, succeeded)
        } else {
            lock.unlock()
        }
    }

    private func extractProjectFromProcessList(_ output: String) -> String {
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

    func checkLastBuildResult(project: String) -> Bool {
        let fm = FileManager.default
        let ddPath = URL(fileURLWithPath: derivedDataPath)

        guard let contents = try? fm.contentsOfDirectory(
            at: ddPath,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return true }

        let sorted = contents
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let date = values.contentModificationDate else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }

        guard let mostRecent = sorted.first else { return true }

        let logsDir = mostRecent.0.appendingPathComponent("Logs/Build")
        guard let logFiles = try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return true
        }

        // Find most recent .xcactivitylog
        let activityLogs = logFiles
            .filter { $0.pathExtension == "xcactivitylog" }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let date = values.contentModificationDate else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }

        guard let latestLog = activityLogs.first else { return true }

        // Decompress and check for Build Failed/Succeeded
        let gunzipProcess = Process()
        gunzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        gunzipProcess.arguments = ["-c", latestLog.0.path]
        let outPipe = Pipe()
        gunzipProcess.standardOutput = outPipe
        gunzipProcess.standardError = Pipe()

        do {
            try gunzipProcess.run()
            gunzipProcess.waitUntilExit()

            let outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
            // Only check the last ~4KB for performance
            let tailSize = min(outputData.count, 4096)
            let tailData = outputData.suffix(tailSize)
            if let tail = String(data: tailData, encoding: .utf8) {
                if tail.contains("Build Failed") {
                    return false
                }
                if tail.contains("Build Succeeded") {
                    return true
                }
            }
            // Fallback: also check with latin1 encoding
            if let tail = String(data: tailData, encoding: .isoLatin1) {
                if tail.contains("Build Failed") {
                    return false
                }
            }
        } catch {
            // If decompression fails, assume success
        }

        return true
    }

    // MARK: - FSEvents

    private func startFSEvents() {
        let pathsToWatch = [derivedDataPath] as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            // FSEvents callback - primarily used to trigger UI refresh
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
