import Foundation
import CoreServices

/// Monitors Xcode builds using a hybrid approach:
/// - Build START: detected via compiler processes (swift-frontend, clang)
/// - Build END: detected via new .xcactivitylog files appearing
/// Works for both Xcode IDE and CLI xcodebuild invocations.
final class BuildTrackerCore: @unchecked Sendable {
    var onBuildStarted: (@Sendable (String) -> Void)?
    var onBuildFinished: (@Sendable (String, TimeInterval, Bool) -> Void)?
    var onDerivedDataChanged: (@Sendable () -> Void)?

    private var eventStream: FSEventStreamRef?
    private var pollTimer: DispatchSourceTimer?
    private let lock = NSLock()
    private let pollQueue = DispatchQueue(label: "com.dimapulse.buildtracker", qos: .utility)

    // Active build tracking
    private var activeBuildProject: String?
    private var buildStartTime: Date?

    // Log-based tracking
    private var knownLogFiles: Set<String> = []
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

    // MARK: - Polling

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1.5)
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        pollTimer = timer
    }

    private func poll() {
        lock.lock()
        let wasBuilding = activeBuildProject != nil
        lock.unlock()

        // Check for build START via compiler processes
        if !wasBuilding {
            let compiling = isCompilerRunning()
            if compiling {
                let project = detectActiveProject()
                lock.lock()
                activeBuildProject = project
                buildStartTime = Date()
                lock.unlock()
                onBuildStarted?(project)
            }
        }

        // Check for build END via new log files
        checkForNewLogFiles()
    }

    // MARK: - Compiler Process Detection (for build START)

    private func isCompilerRunning() -> Bool {
        // swift-frontend = Swift compilation (most reliable, Xcode-specific)
        if processExists("swift-frontend") { return true }
        // clang = C/ObjC compilation
        if processExists("clang") { return true }
        return false
    }

    private func processExists(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", name]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Find which project is being built from most recently modified DerivedData dir
    private func detectActiveProject() -> String {
        let fm = FileManager.default
        let ddURL = URL(fileURLWithPath: derivedDataPath)

        guard let contents = try? fm.contentsOfDirectory(
            at: ddURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return "Xcode Build" }

        if let dir = contents
            .compactMap({ url -> (URL, Date)? in
                guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                      vals.isDirectory == true,
                      let date = vals.contentModificationDate else { return nil }
                return (url, date)
            })
            .max(by: { $0.1 < $1.1 })
        {
            return extractProjectName(from: dir.0.lastPathComponent)
        }
        return "Xcode Build"
    }

    // MARK: - Log File Detection (for build END + fallback)

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
            guard let logFiles = try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) else { continue }

            for logFile in logFiles where logFile.pathExtension == "xcactivitylog" {
                let path = logFile.path

                lock.lock()
                let isKnown = knownLogFiles.contains(path)
                lock.unlock()

                guard !isKnown else { continue }

                // Only process non-empty files (Xcode writes content when build completes)
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let size = attrs[.size] as? UInt64,
                      size > 0 else {
                    continue
                }

                lock.lock()
                knownLogFiles.insert(path)
                let isTracking = activeBuildProject != nil
                let project = activeBuildProject ?? extractProjectName(from: dir.lastPathComponent)
                let startTime = buildStartTime
                // Clear active build
                activeBuildProject = nil
                buildStartTime = nil
                lock.unlock()

                let duration: TimeInterval
                if let start = startTime {
                    // We tracked the start via compiler detection - use real elapsed time
                    duration = Date().timeIntervalSince(start)
                } else {
                    // Missed the start - estimate from file timestamps
                    duration = buildDuration(from: logFile)
                }

                let succeeded = quickCheckBuildResult(at: logFile)

                if !isTracking {
                    // We missed the start, fire both events
                    onBuildStarted?(project)
                }
                onBuildFinished?(project, max(duration, 1), succeeded)
            }
        }
    }

    // MARK: - Build Result Detection

    private func quickCheckBuildResult(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        if fileSize == 0 { return true }
        let readSize: UInt64 = min(fileSize, 4096)
        handle.seek(toFileOffset: fileSize - readSize)
        let tailData = handle.readData(ofLength: Int(readSize))

        if let text = String(data: tailData, encoding: .isoLatin1) {
            if text.contains("Build Failed") || text.contains("BUILD FAILED") {
                return false
            }
        }
        return true
    }

    // MARK: - Helpers

    private func buildDuration(from url: URL) -> TimeInterval {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let created = attrs[.creationDate] as? Date,
              let modified = attrs[.modificationDate] as? Date else {
            return 1
        }
        return max(modified.timeIntervalSince(created), 1)
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

    private var lastDerivedDataNotification = Date.distantPast

    private func startFSEvents() {
        let pathsToWatch = [derivedDataPath] as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let tracker = Unmanaged<BuildTrackerCore>.fromOpaque(info).takeUnretainedValue()

            // Immediately check for new log files (fast build-end detection)
            tracker.pollQueue.async {
                tracker.checkForNewLogFiles()
            }

            // Debounce DerivedData refresh
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
            0.5, // Low latency for fast build-end detection
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        let queue = DispatchQueue(label: "com.dimapulse.fsevents", qos: .utility)
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        eventStream = stream
    }
}
