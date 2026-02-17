import Foundation
import CoreServices
import Compression
import os.log

/// Monitors Xcode builds using two complementary signals:
///
/// **Start detection**: `build.db` modification date advances → build started.
/// Xcode writes to build.db at the beginning of a build (planning phase).
///
/// **End detection**: New `.xcactivitylog` file appears → build finished.
/// Xcode writes the log at the very end of the build. This is ground truth.
///
/// **Canceled builds**: If no xcactivitylog appears and build.db hasn't changed
/// for 30 seconds, the build is assumed canceled.
///
/// Build result: decompress the xcactivitylog (gzip) and search for failure strings.
/// Duration: wallclock from build.db change to xcactivitylog appearance.
final class BuildTrackerCore: @unchecked Sendable {
    var onBuildStarted: (@Sendable (String) -> Void)?
    var onBuildFinished: (@Sendable (String, TimeInterval, Bool) -> Void)?
    var onDerivedDataChanged: (@Sendable () -> Void)?

    private var eventStream: FSEventStreamRef?
    private var pollTimer: DispatchSourceTimer?
    private var completionTimer: DispatchSourceTimer?
    private let lock = NSLock()
    private let pollQueue = DispatchQueue(label: "com.dimapulse.buildtracker", qos: .utility)
    private let log = Logger(subsystem: "com.dimapulse.BuildPulse", category: "BuildTracker")

    private struct ProjectBuildState {
        let projectName: String
        let buildDBPath: String
        let projectDir: URL
        var lastModDate: Date
        var phase: Phase
        var buildStartTime: Date?
        var lastActivityDate: Date?
        var knownLogFiles: Set<String>

        enum Phase: CustomStringConvertible {
            case idle, building
            var description: String {
                switch self {
                case .idle: return "idle"
                case .building: return "building"
                }
            }
        }
    }

    private var projectStates: [String: ProjectBuildState] = [:]

    private let derivedDataPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Developer/Xcode/DerivedData"
    }()

    /// How long to wait with no activity before declaring a canceled build.
    private static let cancelTimeout: TimeInterval = 30.0

    func startMonitoring() {
        log.info("Starting build monitoring at \(self.derivedDataPath)")
        initializeProjectStates()
        startFSEvents()
        startPolling()
        startCompletionChecker()
    }

    func stopMonitoring() {
        log.info("Stopping build monitoring")
        pollTimer?.cancel()
        pollTimer = nil
        completionTimer?.cancel()
        completionTimer = nil
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }
    }

    // MARK: - Initial State

    private func initializeProjectStates() {
        let fm = FileManager.default
        let ddURL = URL(fileURLWithPath: derivedDataPath)
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: ddURL, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ) else {
            log.warning("Could not list DerivedData directory")
            return
        }

        log.info("Found \(projectDirs.count) directories in DerivedData")

        lock.lock()
        defer { lock.unlock() }

        for dir in projectDirs {
            let dirName = dir.lastPathComponent
            let buildDBPath = dir.appendingPathComponent(
                "Build/Intermediates.noindex/XCBuildData/build.db"
            ).path

            guard fm.fileExists(atPath: buildDBPath) else {
                log.debug("No build.db for \(dirName)")
                continue
            }
            guard let modDate = latestBuildDBModDate(at: buildDBPath) else {
                log.warning("Could not stat build.db for \(dirName)")
                continue
            }

            let logFiles = snapshotLogFiles(in: dir)
            log.info("Tracking \(dirName): build.db modDate=\(modDate), \(logFiles.count) existing logs")

            projectStates[dirName] = ProjectBuildState(
                projectName: extractProjectName(from: dirName),
                buildDBPath: buildDBPath,
                projectDir: dir,
                lastModDate: modDate,
                phase: .idle,
                knownLogFiles: logFiles
            )
        }

        log.info("Initialized \(self.projectStates.count) project states")
    }

    // MARK: - Build Start Detection (build.db monitoring)

    func checkBuildDatabases() {
        let fm = FileManager.default
        let ddURL = URL(fileURLWithPath: derivedDataPath)
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: ddURL, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ) else { return }

        let now = Date()
        var startedProjects: [String] = []

        lock.lock()

        for dir in projectDirs {
            let dirName = dir.lastPathComponent
            let buildDBPath = dir.appendingPathComponent(
                "Build/Intermediates.noindex/XCBuildData/build.db"
            ).path

            guard fm.fileExists(atPath: buildDBPath),
                  let modDate = latestBuildDBModDate(at: buildDBPath) else { continue }

            if var state = projectStates[dirName] {
                if modDate > state.lastModDate {
                    state.lastModDate = modDate
                    state.lastActivityDate = now

                    switch state.phase {
                    case .idle:
                        state.phase = .building
                        state.buildStartTime = now
                        state.knownLogFiles = snapshotLogFiles(in: dir)
                        projectStates[dirName] = state
                        startedProjects.append(state.projectName)
                        log.info("[\(state.projectName)] BUILD STARTED — build.db modified: \(modDate) (snapshotted \(state.knownLogFiles.count) existing logs)")

                    case .building:
                        // build.db changed again during build (e.g., end-of-build write)
                        projectStates[dirName] = state
                        log.info("[\(state.projectName)] build.db updated during build: \(modDate)")
                    }
                }
            } else {
                let projectName = extractProjectName(from: dirName)
                let logFiles = snapshotLogFiles(in: dir)
                projectStates[dirName] = ProjectBuildState(
                    projectName: projectName,
                    buildDBPath: buildDBPath,
                    projectDir: dir,
                    lastModDate: modDate,
                    phase: .idle,
                    knownLogFiles: logFiles
                )
                log.info("Discovered new project: \(projectName) (modDate: \(modDate), \(logFiles.count) logs)")
            }
        }

        lock.unlock()

        for project in startedProjects {
            log.info("Firing onBuildStarted for \(project)")
            onBuildStarted?(project)
        }
    }

    // MARK: - Build Completion Detection (xcactivitylog polling)

    private func startCompletionChecker() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.checkBuildCompletion()
        }
        timer.resume()
        completionTimer = timer
    }

    private func checkBuildCompletion() {
        let now = Date()

        struct FinishedBuild {
            let projectName: String
            let duration: TimeInterval
            let projectDir: URL
            let knownLogs: Set<String>
            let newLogURL: URL?
        }
        var finishedBuilds: [FinishedBuild] = []

        lock.lock()

        for (dirName, var state) in projectStates {
            guard state.phase == .building else { continue }

            // Check for new xcactivitylog files
            let currentLogs = snapshotLogFiles(in: state.projectDir)
            let newLogs = currentLogs.subtracting(state.knownLogFiles)

            if !newLogs.isEmpty {
                // New xcactivitylog appeared — but is the build really done?
                // Xcode writes small "Prepare build" / "Clean" logs immediately at
                // the start. We must verify compilation has actually finished.
                let fm = FileManager.default
                let newestLogURL = newLogs
                    .compactMap { path -> (URL, Date)? in
                        let url = URL(fileURLWithPath: path)
                        guard let attrs = try? fm.attributesOfItem(atPath: path),
                              let modDate = attrs[.modificationDate] as? Date else { return nil }
                        let size = (attrs[.size] as? UInt64) ?? 0
                        guard size > 0 else { return nil }
                        return (url, modDate)
                    }
                    .max(by: { $0.1 < $1.1 })

                guard let (logURL, logDate) = newestLogURL else {
                    log.debug("[\(state.projectName)] new log files found but empty, waiting...")
                    continue
                }

                // Grace period: don't finish within 3s of build start (processes may
                // not have spawned yet after the "Prepare build" log).
                let elapsed = now.timeIntervalSince(state.buildStartTime ?? now)
                if elapsed < 3 {
                    log.info("[\(state.projectName)] new log \(logURL.lastPathComponent) but only \(String(format: "%.1f", elapsed))s since start, waiting...")
                    continue
                }

                // Check if compilation processes are still running for this project.
                // Release the lock during the (brief) pgrep call to avoid blocking.
                lock.unlock()
                let processesRunning = hasBuildProcesses(forProject: dirName)
                lock.lock()

                // Re-read state in case it changed while lock was released
                guard var freshState = projectStates[dirName],
                      freshState.phase == .building else { continue }

                if processesRunning {
                    log.info("[\(state.projectName)] new log \(logURL.lastPathComponent) but build processes still running, waiting...")
                    continue
                }

                let duration = max(logDate.timeIntervalSince(freshState.buildStartTime ?? now), 1)
                log.info("[\(freshState.projectName)] xcactivitylog appeared: \(logURL.lastPathComponent), logDate=\(logDate), duration=\(String(format: "%.1f", duration))s")

                finishedBuilds.append(FinishedBuild(
                    projectName: freshState.projectName,
                    duration: duration,
                    projectDir: freshState.projectDir,
                    knownLogs: freshState.knownLogFiles,
                    newLogURL: logURL
                ))

                freshState.phase = .idle
                freshState.buildStartTime = nil
                freshState.lastActivityDate = nil
                freshState.knownLogFiles = currentLogs
                projectStates[dirName] = freshState
                continue
            }

            // Also refresh build.db mod date to track activity
            if let modDate = latestBuildDBModDate(at: state.buildDBPath),
               modDate > state.lastModDate {
                state.lastModDate = modDate
                state.lastActivityDate = now
                projectStates[dirName] = state
                log.info("[\(state.projectName)] build.db activity detected during completion check: \(modDate)")
                continue
            }

            // Fallback: cancel timeout — but only if build processes have stopped
            let lastActivity = state.lastActivityDate ?? state.buildStartTime ?? now
            let inactiveTime = now.timeIntervalSince(lastActivity)
            if inactiveTime >= Self.cancelTimeout {
                // Check if build processes are still running before timing out
                lock.unlock()
                let processesRunning = hasBuildProcesses(forProject: dirName)
                lock.lock()

                guard var freshState = projectStates[dirName],
                      freshState.phase == .building else { continue }

                if processesRunning {
                    // Processes still running — build is active, extend timeout
                    freshState.lastActivityDate = now
                    projectStates[dirName] = freshState
                    log.info("[\(freshState.projectName)] cancel timeout reached but build processes still running (\(String(format: "%.0f", inactiveTime))s), extending...")
                    continue
                }

                let duration = max(now.timeIntervalSince(freshState.buildStartTime ?? now), 1)
                log.info("[\(freshState.projectName)] CANCEL TIMEOUT — no xcactivitylog, no processes, no activity for \(String(format: "%.0f", inactiveTime))s")

                finishedBuilds.append(FinishedBuild(
                    projectName: freshState.projectName,
                    duration: duration,
                    projectDir: freshState.projectDir,
                    knownLogs: freshState.knownLogFiles,
                    newLogURL: nil
                ))

                freshState.phase = .idle
                freshState.buildStartTime = nil
                freshState.lastActivityDate = nil
                projectStates[dirName] = freshState
            }
        }

        lock.unlock()

        for build in finishedBuilds {
            let succeeded: Bool
            if let logURL = build.newLogURL {
                succeeded = checkBuildSucceeded(logURL: logURL)
            } else {
                succeeded = false // Canceled / timed out
            }
            log.info("[\(build.projectName)] BUILD FINISHED — duration=\(String(format: "%.1f", build.duration))s, succeeded=\(succeeded)")
            onBuildFinished?(build.projectName, build.duration, succeeded)
        }
    }

    // MARK: - Build Result Detection

    private func checkBuildSucceeded(logURL: URL) -> Bool {
        guard let compressedData = try? Data(contentsOf: logURL) else {
            log.warning("Could not read xcactivitylog at \(logURL.lastPathComponent)")
            return true
        }
        log.info("xcactivitylog size: \(compressedData.count) bytes")

        guard compressedData.count > 18 else {
            log.warning("xcactivitylog too small (\(compressedData.count) bytes), assuming success")
            return true
        }

        let headerBytes = compressedData.prefix(10).map { String(format: "%02x", $0) }.joined(separator: " ")
        log.info("Header bytes: \(headerBytes)")

        let headerSize = gzipHeaderSize(of: compressedData)
        guard headerSize > 0, headerSize < compressedData.count else {
            log.warning("Invalid gzip header (headerSize=\(headerSize)), assuming success")
            return true
        }

        // Uncompressed size from gzip trailer (last 4 bytes, little-endian, mod 2^32)
        let c = compressedData.count
        let sizeHint = Int(compressedData[c-4])
            | (Int(compressedData[c-3]) << 8)
            | (Int(compressedData[c-2]) << 16)
            | (Int(compressedData[c-1]) << 24)
        let bufferSize = sizeHint > 0
            ? min(sizeHint, 50_000_000)
            : min(compressedData.count * 10, 50_000_000)
        log.info("Decompression: sizeHint=\(sizeHint), bufferSize=\(bufferSize)")

        let destBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destBuffer.deallocate() }

        let deflateData = compressedData[headerSize...]
        let decodedSize = deflateData.withUnsafeBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            else { return 0 }
            return compression_decode_buffer(
                destBuffer, bufferSize,
                base, rawBuffer.count,
                nil, COMPRESSION_ZLIB
            )
        }

        log.info("Decompressed: \(decodedSize) bytes")

        guard decodedSize > 0 else {
            log.warning("Decompression produced 0 bytes, assuming success")
            return true
        }

        let decompressed = Data(bytes: destBuffer, count: decodedSize)

        if let sample = String(data: decompressed.prefix(200), encoding: .utf8) {
            log.info("Decompressed sample: \(sample)")
        }

        let hasBuildFailed = decompressed.range(of: Data("Build Failed".utf8)) != nil
        let hasBUILD_FAILED = decompressed.range(of: Data("BUILD FAILED".utf8)) != nil

        log.info("Failure string search: 'Build Failed'=\(hasBuildFailed), 'BUILD FAILED'=\(hasBUILD_FAILED)")

        if hasBuildFailed || hasBUILD_FAILED { return false }
        return true
    }

    /// Parse gzip header to find where the raw deflate stream begins.
    private func gzipHeaderSize(of data: Data) -> Int {
        guard data.count >= 10,
              data[0] == 0x1f, data[1] == 0x8b, data[2] == 0x08 else { return 0 }

        let flags = data[3]
        var offset = 10

        if flags & 0x04 != 0 { // FEXTRA
            guard data.count > offset + 2 else { return 0 }
            let extraLen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + extraLen
        }
        if flags & 0x08 != 0 { // FNAME
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { // FHCRC
            offset += 2
        }

        return min(offset, data.count)
    }

    // MARK: - Helpers

    /// Checks if any compilation processes (swift-frontend, clang, swiftc)
    /// are running with this project's DerivedData directory in their arguments.
    /// Uses a narrow regex to avoid matching Xcode, SourceKitService, or other
    /// persistent processes that also reference the DerivedData path.
    private func hasBuildProcesses(forProject dirName: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-qf", "(swift-frontend|clang|swiftc).*\(dirName)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Returns the latest modification date across build.db and its journal/WAL/SHM files.
    private func latestBuildDBModDate(at buildDBPath: String) -> Date? {
        let fm = FileManager.default
        var latest: Date?
        for suffix in ["", "-wal", "-shm", "-journal"] {
            guard let attrs = try? fm.attributesOfItem(atPath: buildDBPath + suffix),
                  let modDate = attrs[.modificationDate] as? Date else { continue }
            if latest == nil || modDate > latest! {
                latest = modDate
            }
        }
        return latest
    }

    private func snapshotLogFiles(in projectDir: URL) -> Set<String> {
        let logsDir = projectDir.appendingPathComponent("Logs/Build")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logsDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return Set(files.filter { $0.pathExtension == "xcactivitylog" }.map(\.path))
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

    // MARK: - Polling (fallback for FSEvents)

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 3, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            self?.checkBuildDatabases()
        }
        timer.resume()
        pollTimer = timer
    }

    // MARK: - FSEvents

    private var lastDerivedDataNotification = Date.distantPast

    private func startFSEvents() {
        let pathsToWatch = [derivedDataPath] as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let tracker = Unmanaged<BuildTrackerCore>.fromOpaque(info).takeUnretainedValue()

            tracker.pollQueue.async {
                tracker.checkBuildDatabases()
            }

            let now = Date()
            if now.timeIntervalSince(tracker.lastDerivedDataNotification) > 5 {
                tracker.lastDerivedDataNotification = now
                tracker.onDerivedDataChanged?()
            }
        }

        guard let stream = FSEventStreamCreate(
            nil, callback, &context, pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else {
            log.error("Failed to create FSEventStream")
            return
        }

        let queue = DispatchQueue(label: "com.dimapulse.fsevents", qos: .utility)
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        eventStream = stream
        log.info("FSEvents stream started")
    }
}
