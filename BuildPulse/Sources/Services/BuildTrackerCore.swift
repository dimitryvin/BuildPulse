import Foundation
import CoreServices

/// Monitors Xcode builds by detecting compiler processes and .xcactivitylog files.
/// Works for both Xcode IDE and CLI xcodebuild invocations.
final class BuildTrackerCore: @unchecked Sendable {
    var onBuildStarted: (@Sendable (String) -> Void)?
    var onBuildFinished: (@Sendable (String, TimeInterval, Bool) -> Void)?
    var onDerivedDataChanged: (@Sendable () -> Void)?

    private var eventStream: FSEventStreamRef?
    private var pollTimer: DispatchSourceTimer?
    private let lock = NSLock()
    private let pollQueue = DispatchQueue(label: "com.dimapulse.buildtracker", qos: .utility)

    // Active build tracking (compiler process-based)
    private var activeBuildProject: String?
    private var buildStartTime: Date?
    private var idlePollCount = 0 // consecutive polls with no compiler processes

    // Log-based tracking for success/failure
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
        let compiling = isCompilerRunning()

        lock.lock()
        let wasBuilding = activeBuildProject != nil
        lock.unlock()

        if compiling && !wasBuilding {
            // Build just started - detect project from most recently modified DerivedData dir
            let project = detectActiveProject()
            lock.lock()
            activeBuildProject = project
            buildStartTime = Date()
            idlePollCount = 0
            lock.unlock()
            onBuildStarted?(project)

        } else if compiling && wasBuilding {
            // Still building
            lock.lock()
            idlePollCount = 0
            lock.unlock()

        } else if !compiling && wasBuilding {
            // Compiler processes gone - wait a couple polls to confirm build is truly done
            // (there can be brief gaps between compilation phases)
            lock.lock()
            idlePollCount += 1
            let idle = idlePollCount
            lock.unlock()

            if idle >= 2 {
                // Build finished
                lock.lock()
                let project = activeBuildProject ?? "Unknown"
                let startTime = buildStartTime ?? Date()
                activeBuildProject = nil
                buildStartTime = nil
                idlePollCount = 0
                lock.unlock()

                let duration = Date().timeIntervalSince(startTime)
                let succeeded = checkBuildResult()
                onBuildFinished?(project, max(duration, 1), succeeded)
            }
        }

        // Also check for new log files (catches builds we might have missed)
        checkForNewLogFiles()
    }

    // MARK: - Compiler Process Detection

    private func isCompilerRunning() -> Bool {
        // Check for swift-frontend, clang, or xcodebuild processes
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "swift-frontend"]
        process.standardOutput = pipe
        process.standardError = Pipe()

        try? process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            return true
        }

        // Also check for clang (C/ObjC compilation)
        let pipe2 = Pipe()
        let process2 = Process()
        process2.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process2.arguments = ["-x", "clang"]
        process2.standardOutput = pipe2
        process2.standardError = Pipe()

        try? process2.run()
        process2.waitUntilExit()

        if process2.terminationStatus == 0 {
            return true
        }

        // Also check for linker (ld)
        let pipe3 = Pipe()
        let process3 = Process()
        process3.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process3.arguments = ["-x", "ld"]
        process3.standardOutput = pipe3
        process3.standardError = Pipe()

        try? process3.run()
        process3.waitUntilExit()

        return process3.terminationStatus == 0
    }

    /// Find which project is being built by checking most recently modified DerivedData dir
    private func detectActiveProject() -> String {
        let fm = FileManager.default
        let ddURL = URL(fileURLWithPath: derivedDataPath)

        guard let contents = try? fm.contentsOfDirectory(
            at: ddURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return "Xcode Build" }

        let mostRecent = contents
            .compactMap { url -> (URL, Date)? in
                guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                      vals.isDirectory == true,
                      let date = vals.contentModificationDate else { return nil }
                return (url, date)
            }
            .max { $0.1 < $1.1 }

        if let dir = mostRecent {
            return extractProjectName(from: dir.0.lastPathComponent)
        }
        return "Xcode Build"
    }

    // MARK: - Build Result Detection

    private func checkBuildResult() -> Bool {
        let fm = FileManager.default
        let ddURL = URL(fileURLWithPath: derivedDataPath)

        guard let contents = try? fm.contentsOfDirectory(
            at: ddURL,
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

        let logsDir = mostRecent.0.appendingPathComponent("Logs/Build")
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

        return quickCheckBuildResult(at: latestLog.0)
    }

    /// Quick check by reading compressed file tail (no decompression)
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

    // MARK: - Log File Detection (fallback for missed builds)

    private func checkForNewLogFiles() {
        guard hasScannedInitialLogs else { return }
        let fm = FileManager.default
        let ddURL = URL(fileURLWithPath: derivedDataPath)

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: ddURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return }

        lock.lock()
        let isActivelyTracking = activeBuildProject != nil
        lock.unlock()

        for dir in projectDirs {
            let logsDir = dir.appendingPathComponent("Logs/Build")
            guard let logFiles = try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) else { continue }

            for logFile in logFiles where logFile.pathExtension == "xcactivitylog" {
                let path = logFile.path

                lock.lock()
                let isKnown = knownLogFiles.contains(path)
                lock.unlock()

                if !isKnown {
                    // Check if file has content (not just a placeholder)
                    guard let attrs = try? fm.attributesOfItem(atPath: path),
                          let size = attrs[.size] as? UInt64,
                          size > 0 else {
                        continue
                    }

                    lock.lock()
                    knownLogFiles.insert(path)
                    lock.unlock()

                    // Only report if we're not already tracking via compiler detection
                    if !isActivelyTracking {
                        let projectName = extractProjectName(from: dir.lastPathComponent)
                        let duration = buildDuration(from: logFile)
                        let succeeded = quickCheckBuildResult(at: logFile)
                        onBuildFinished?(projectName, duration, succeeded)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func buildDuration(from url: URL) -> TimeInterval {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let created = attrs[.creationDate] as? Date,
              let modified = attrs[.modificationDate] as? Date else {
            return 1
        }
        let duration = modified.timeIntervalSince(created)
        return max(duration, 1)
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
            2.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        let queue = DispatchQueue(label: "com.dimapulse.fsevents", qos: .utility)
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        eventStream = stream
    }
}
