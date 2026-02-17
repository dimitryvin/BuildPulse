import Foundation
import CoreServices

/// Monitors Xcode builds by watching for .xcactivitylog files in DerivedData.
/// Detects both Xcode IDE builds and CLI `xcodebuild` invocations.
final class BuildTrackerCore: @unchecked Sendable {
    var onBuildStarted: (@Sendable (String) -> Void)?
    var onBuildFinished: (@Sendable (String, TimeInterval, Bool) -> Void)?
    var onDerivedDataChanged: (@Sendable () -> Void)?

    private var eventStream: FSEventStreamRef?
    private var pollTimer: DispatchSourceTimer?
    private let lock = NSLock()
    private let pollQueue = DispatchQueue(label: "com.dimapulse.buildtracker", qos: .utility)

    // CLI build tracking
    private var activeCLIBuildProject: String?
    private var cliBuildStartTime: Date?

    // Log-based tracking (Xcode IDE builds)
    private var knownLogFiles: Set<String> = []
    /// 0-byte logs we've seen (build started but not finished) -> (projectName, startTime)
    private var pendingBuilds: [String: (project: String, startTime: Date)] = [:]
    private var hasScannedInitialLogs = false

    private let derivedDataPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Developer/Xcode/DerivedData"
    }()

    func startMonitoring() {
        scanExistingLogFiles()
        startFSEvents()
        startPolling()
    }

    func stopMonitoring() {
        pollTimer?.cancel()
        pollTimer = nil

        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }
    }

    // MARK: - Initial Log Snapshot

    private func scanExistingLogFiles() {
        let fm = FileManager.default
        let ddURL = URL(fileURLWithPath: derivedDataPath)
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: ddURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return }

        for dir in projectDirs {
            let logsDir = dir.appendingPathComponent("Logs/Build")
            guard let logFiles = try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) else { continue }
            for logFile in logFiles where logFile.pathExtension == "xcactivitylog" {
                knownLogFiles.insert(logFile.path)
            }
        }
        hasScannedInitialLogs = true
    }

    private func fileSize(at path: String) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return 0 }
        return size
    }

    // MARK: - Polling on background queue

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 2, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            self?.pollForBuilds()
        }
        timer.resume()
        pollTimer = timer
    }

    private func pollForBuilds() {
        checkForCLIBuilds()
        checkForNewLogFiles()
    }

    // MARK: - CLI Build Detection

    private func checkForCLIBuilds() {
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
        if isBuilding && activeCLIBuildProject == nil {
            let project = extractProjectFromProcessList(output)
            activeCLIBuildProject = project
            cliBuildStartTime = Date()
            lock.unlock()
            onBuildStarted?(project)
        } else if !isBuilding && activeCLIBuildProject != nil {
            let duration = Date().timeIntervalSince(cliBuildStartTime ?? Date())
            let project = activeCLIBuildProject ?? "Unknown"
            activeCLIBuildProject = nil
            cliBuildStartTime = nil
            lock.unlock()
            let succeeded = parseBuildResult(forProject: nil)
            onBuildFinished?(project, duration, succeeded)
        } else {
            lock.unlock()
        }
    }

    // MARK: - Log File Detection (Xcode IDE builds)

    private func checkForNewLogFiles() {
        guard hasScannedInitialLogs else { return }
        let fm = FileManager.default
        let ddURL = URL(fileURLWithPath: derivedDataPath)

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: ddURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return }

        for dir in projectDirs {
            let logsDir = dir.appendingPathComponent("Logs/Build")
            guard let logFiles = try? fm.contentsOfDirectory(
                at: logsDir,
                includingPropertiesForKeys: nil
            ) else { continue }

            for logFile in logFiles where logFile.pathExtension == "xcactivitylog" {
                let path = logFile.path
                let size = fileSize(at: path)

                lock.lock()
                let isKnown = knownLogFiles.contains(path)
                let isPending = pendingBuilds[path] != nil
                let hasCLIBuild = activeCLIBuildProject != nil
                lock.unlock()

                if hasCLIBuild { continue }

                if !isKnown && size == 0 && !isPending {
                    // New empty log file = build just started
                    let projectName = extractProjectName(from: dir.lastPathComponent)
                    lock.lock()
                    pendingBuilds[path] = (project: projectName, startTime: Date())
                    lock.unlock()
                    onBuildStarted?(projectName)

                } else if isPending && size > 0 {
                    // Pending build's log now has content = build finished
                    lock.lock()
                    let buildInfo = pendingBuilds.removeValue(forKey: path)
                    knownLogFiles.insert(path)
                    lock.unlock()

                    if let info = buildInfo {
                        let duration = Date().timeIntervalSince(info.startTime)
                        let succeeded = quickCheckBuildResult(at: logFile)
                        onBuildFinished?(info.project, max(duration, 1), succeeded)
                    }

                } else if !isKnown && size > 0 {
                    // Non-empty log we haven't seen (missed the start)
                    lock.lock()
                    knownLogFiles.insert(path)
                    lock.unlock()

                    let projectName = extractProjectName(from: dir.lastPathComponent)
                    let duration = buildDuration(from: logFile)
                    let succeeded = quickCheckBuildResult(at: logFile)
                    onBuildFinished?(projectName, duration, succeeded)
                }
            }
        }
    }

    // MARK: - Lightweight Build Info

    /// Get build duration from file timestamps (instant, no decompression)
    private func buildDuration(from url: URL) -> TimeInterval {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let created = attrs[.creationDate] as? Date,
              let modified = attrs[.modificationDate] as? Date else {
            return 1
        }
        let duration = modified.timeIntervalSince(created)
        return max(duration, 1)
    }

    /// Quick check build result by reading just the compressed file's tail
    /// without full decompression. Falls back to true (success) if uncertain.
    private func quickCheckBuildResult(at url: URL) -> Bool {
        // Read last 2KB of the compressed file directly (no decompression)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 4096)
        handle.seek(toFileOffset: fileSize - readSize)
        let tailData = handle.readData(ofLength: Int(readSize))

        // Check raw bytes for failure markers (these strings appear even compressed sometimes)
        if let text = String(data: tailData, encoding: .isoLatin1) {
            if text.contains("Build Failed") || text.contains("BUILD FAILED") {
                return false
            }
        }

        return true
    }

    // MARK: - Full Build Log Parsing (used by CLI detection)

    private func parseBuildLog(at url: URL) -> (TimeInterval, Bool) {
        let gunzipProcess = Process()
        gunzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        gunzipProcess.arguments = ["-c", url.path]
        let outPipe = Pipe()
        gunzipProcess.standardOutput = outPipe
        gunzipProcess.standardError = Pipe()

        do {
            try gunzipProcess.run()
            gunzipProcess.waitUntilExit()

            let outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let succeeded: Bool
            let tailSize = min(outputData.count, 8192)
            let tailData = outputData.suffix(tailSize)

            if let tail = String(data: tailData, encoding: .utf8) {
                if tail.contains("Build Failed") || tail.contains("BUILD FAILED") {
                    succeeded = false
                } else {
                    succeeded = true
                }
            } else if let tail = String(data: tailData, encoding: .isoLatin1) {
                succeeded = !tail.contains("Build Failed") && !tail.contains("BUILD FAILED")
            } else {
                succeeded = true
            }

            // Try file timestamps for duration
            var duration: TimeInterval = 0
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let created = attrs[.creationDate] as? Date,
               let modified = attrs[.modificationDate] as? Date {
                duration = modified.timeIntervalSince(created)
                if duration < 0 { duration = 0 }
            }

            return (max(duration, 1), succeeded)
        } catch {
            return (0, true)
        }
    }

    func parseBuildResult(forProject projectDir: URL?) -> Bool {
        let fm = FileManager.default
        let ddPath = URL(fileURLWithPath: derivedDataPath)

        let targetDir: URL
        if let dir = projectDir {
            targetDir = dir
        } else {
            guard let contents = try? fm.contentsOfDirectory(
                at: ddPath,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { return true }

            guard let mostRecent = contents
                .compactMap({ url -> (URL, Date)? in
                    guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                          let date = vals.contentModificationDate else { return nil }
                    return (url, date)
                })
                .max(by: { $0.1 < $1.1 })
            else { return true }

            targetDir = mostRecent.0
        }

        let logsDir = targetDir.appendingPathComponent("Logs/Build")
        guard let logFiles = try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return true
        }

        guard let latestLog = logFiles
            .filter({ $0.pathExtension == "xcactivitylog" })
            .compactMap({ url -> (URL, Date)? in
                guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let date = vals.contentModificationDate else { return nil }
                return (url, date)
            })
            .max(by: { $0.1 < $1.1 })
        else { return true }

        return parseBuildLog(at: latestLog.0).1
    }

    // MARK: - Helpers

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

    private func extractProjectName(from dirName: String) -> String {
        if let dashRange = dirName.range(of: "-", options: .backwards) {
            let suffix = dirName[dashRange.upperBound...]
            if suffix.count >= 12 {
                return String(dirName[..<dashRange.lowerBound])
            }
        }
        return dirName
    }

    // MARK: - FSEvents

    /// Debounce DerivedData refresh notifications (don't spam on rapid file changes)
    private var lastDerivedDataNotification = Date.distantPast

    private func startFSEvents() {
        let pathsToWatch = [derivedDataPath] as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let tracker = Unmanaged<BuildTrackerCore>.fromOpaque(info).takeUnretainedValue()

            // Immediately check for new build logs (sub-second detection)
            tracker.checkForNewLogFiles()

            // Debounce DerivedData refresh (every 5s max)
            let now = Date()
            if now.timeIntervalSince(tracker.lastDerivedDataNotification) > 5 {
                tracker.lastDerivedDataNotification = now
                tracker.onDerivedDataChanged?()
            }
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // Low latency for fast build detection
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        let queue = DispatchQueue(label: "com.dimapulse.fsevents", qos: .utility)
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        eventStream = stream
    }
}
