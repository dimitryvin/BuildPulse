import Foundation
import CoreServices

/// Monitors Xcode builds by watching xcactivitylog files in DerivedData.
/// - Build detected when new non-empty .xcactivitylog appears
/// - FSEvents provides near-instant notification (0.5s latency)
/// - Polling every 5s as fallback
/// Works for both Xcode IDE and CLI xcodebuild invocations.
final class BuildTrackerCore: @unchecked Sendable {
    var onBuildStarted: (@Sendable (String) -> Void)?
    var onBuildFinished: (@Sendable (String, TimeInterval, Bool) -> Void)?
    var onDerivedDataChanged: (@Sendable () -> Void)?

    private var eventStream: FSEventStreamRef?
    private var pollTimer: DispatchSourceTimer?
    private let lock = NSLock()
    private let pollQueue = DispatchQueue(label: "com.dimapulse.buildtracker", qos: .utility)

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

    // MARK: - Initial Snapshot

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

    // MARK: - Polling (fallback, FSEvents is primary)

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 3, repeating: 5.0)
        timer.setEventHandler { [weak self] in
            self?.checkForNewLogFiles()
        }
        timer.resume()
        pollTimer = timer
    }

    // MARK: - Log File Detection

    func checkForNewLogFiles() {
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

                guard let attrs = try? fm.attributesOfItem(atPath: path) else { continue }
                let size = (attrs[.size] as? UInt64) ?? 0

                // Skip empty files (build not finished yet)
                guard size > 0 else { continue }

                lock.lock()
                knownLogFiles.insert(path)
                lock.unlock()

                let projectName = extractProjectName(from: dir.lastPathComponent)
                let succeeded = quickCheckBuildResult(at: logFile)
                let duration = buildDuration(from: attrs)

                // Fire both start + finish so the build is recorded
                onBuildStarted?(projectName)
                onBuildFinished?(projectName, max(duration, 1), succeeded)
            }
        }
    }

    // MARK: - Build Result

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

    private func buildDuration(from attrs: [FileAttributeKey: Any]) -> TimeInterval {
        if let created = attrs[.creationDate] as? Date,
           let modified = attrs[.modificationDate] as? Date {
            let duration = modified.timeIntervalSince(created)
            if duration > 0 { return duration }
        }
        return 1
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

            // Check for new log files immediately
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
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        let queue = DispatchQueue(label: "com.dimapulse.fsevents", qos: .utility)
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        eventStream = stream
    }
}
