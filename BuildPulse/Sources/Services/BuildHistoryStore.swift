import Foundation

final class BuildHistoryStore {
    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("BuildPulse")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("build_history.json")
    }()

    func load() -> [BuildRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([BuildRecord].self, from: data) else {
            return []
        }
        return records
    }

    func save(_ records: [BuildRecord]) {
        // Keep last 1000 records
        let trimmed = Array(records.prefix(1000))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
