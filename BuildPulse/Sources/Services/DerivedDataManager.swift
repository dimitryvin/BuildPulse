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

    /// Lightweight directory listing with cache lookup.
    /// Returns projects (with cached sizes or 0) and indices that need size computation.
    func listProjects() -> (projects: [DerivedDataProject], totalSize: Int64, uncachedIndices: [Int]) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: derivedDataURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], 0, [])
        }

        var projects: [DerivedDataProject] = []
        var totalSize: Int64 = 0
        var uncachedIndices: [Int] = []
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
                size = 0
                uncachedIndices.append(projects.count)
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

        return (projects, totalSize, uncachedIndices)
    }

    /// Compute size for a single project and cache it.
    func computeSize(for project: DerivedDataProject) -> Int64 {
        let size = directorySize(at: project.path)
        sizeCache[project.id] = (modified: project.lastModified, size: size)
        return size
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
