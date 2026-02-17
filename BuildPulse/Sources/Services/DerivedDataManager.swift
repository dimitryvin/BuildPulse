import Foundation

actor DerivedDataManager {
    private let derivedDataURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    }()

    /// Cache: dirName -> (lastModified, sizeBytes)
    private var sizeCache: [String: (modified: Date, size: Int64)] = [:]

    /// Full scan returning everything at once (used by delete flows).
    func scan() -> ([DerivedDataProject], Int64) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: derivedDataURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], 0)
        }

        var projects: [DerivedDataProject] = []
        var totalSize: Int64 = 0
        var currentDirNames = Set<String>()

        for url in contents {
            guard let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  resourceValues.isDirectory == true else { continue }

            let dirName = url.lastPathComponent
            currentDirNames.insert(dirName)
            let projectName = extractProjectName(from: dirName)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast

            let size: Int64
            if let cached = sizeCache[dirName], cached.modified == modified {
                size = cached.size
            } else {
                size = directorySize(at: url)
                sizeCache[dirName] = (modified: modified, size: size)
            }

            projects.append(DerivedDataProject(
                id: dirName,
                name: projectName,
                path: url,
                sizeBytes: size,
                lastModified: modified
            ))
            totalSize += size
        }

        for key in sizeCache.keys where !currentDirNames.contains(key) {
            sizeCache.removeValue(forKey: key)
        }

        return (projects.sorted(), totalSize)
    }

    /// Incremental scan: yields partial results as each project's size is computed.
    /// First yields all projects with cached sizes (or 0 for uncached), then updates
    /// each uncached project's size one at a time.
    func scanIncremental() -> AsyncStream<([DerivedDataProject], Int64)> {
        AsyncStream { continuation in
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(
                at: self.derivedDataURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continuation.yield(([], 0))
                continuation.finish()
                return
            }

            // Phase 1: Build project list using cached sizes where available
            var projects: [DerivedDataProject] = []
            var totalSize: Int64 = 0
            var uncachedIndices: [Int] = []
            var currentDirNames = Set<String>()

            for url in contents {
                guard let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                      resourceValues.isDirectory == true else { continue }

                let dirName = url.lastPathComponent
                currentDirNames.insert(dirName)
                let projectName = self.extractProjectName(from: dirName)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast

                let size: Int64
                let needsCompute: Bool
                if let cached = self.sizeCache[dirName], cached.modified == modified {
                    size = cached.size
                    needsCompute = false
                } else {
                    size = 0
                    needsCompute = true
                }

                let index = projects.count
                projects.append(DerivedDataProject(
                    id: dirName,
                    name: projectName,
                    path: url,
                    sizeBytes: size,
                    lastModified: modified
                ))
                totalSize += size

                if needsCompute {
                    uncachedIndices.append(index)
                }
            }

            // Evict stale cache entries
            for key in self.sizeCache.keys where !currentDirNames.contains(key) {
                self.sizeCache.removeValue(forKey: key)
            }

            // Yield immediately with cached sizes (uncached show as 0)
            continuation.yield((projects.sorted(), totalSize))

            // Phase 2: Compute uncached sizes one by one, yielding after each
            for index in uncachedIndices {
                let project = projects[index]
                let computedSize = self.directorySize(at: project.path)
                self.sizeCache[project.id] = (modified: project.lastModified, size: computedSize)

                totalSize += computedSize
                projects[index] = DerivedDataProject(
                    id: project.id,
                    name: project.name,
                    path: project.path,
                    sizeBytes: computedSize,
                    lastModified: project.lastModified
                )

                continuation.yield((projects.sorted(), totalSize))
            }

            continuation.finish()
        }
    }

    func delete(project: DerivedDataProject) {
        sizeCache.removeValue(forKey: project.id)
        try? FileManager.default.removeItem(at: project.path)
    }

    func deleteOlderThan(days: Int) -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let (projects, _) = scan()
        var count = 0
        for project in projects where project.lastModified < cutoff {
            sizeCache.removeValue(forKey: project.id)
            try? FileManager.default.removeItem(at: project.path)
            count += 1
        }
        return count
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

    private func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var size: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey]),
                  resourceValues.isDirectory == false else { continue }
            size += Int64(resourceValues.totalFileAllocatedSize ?? 0)
        }
        return size
    }
}
