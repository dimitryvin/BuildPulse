import Foundation

struct DerivedDataProject: Identifiable, Comparable {
    let id: String
    let name: String
    let path: URL
    var sizeBytes: Int64
    var lastModified: Date

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    static func < (lhs: DerivedDataProject, rhs: DerivedDataProject) -> Bool {
        lhs.sizeBytes > rhs.sizeBytes // largest first
    }
}

struct BuildRecord: Identifiable, Codable {
    let id: UUID
    let scheme: String
    let project: String
    let startTime: Date
    let duration: TimeInterval
    let succeeded: Bool

    init(scheme: String, project: String, startTime: Date, duration: TimeInterval, succeeded: Bool) {
        self.id = UUID()
        self.scheme = scheme
        self.project = project
        self.startTime = startTime
        self.duration = duration
        self.succeeded = succeeded
    }

    var durationFormatted: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

struct BuildStats {
    let totalBuilds: Int
    let avgDuration: TimeInterval
    let totalTime: TimeInterval
    let successRate: Double

    var avgFormatted: String {
        let seconds = Int(avgDuration)
        if seconds >= 60 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds)s"
    }

    var totalFormatted: String {
        let hours = Int(totalTime) / 3600
        let minutes = (Int(totalTime) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

enum TimeRange: String, CaseIterable {
    case today = "Today"
    case week = "This Week"
    case month = "This Month"
    case allTime = "All Time"

    var startDate: Date {
        let cal = Calendar.current
        switch self {
        case .today: return cal.startOfDay(for: Date())
        case .week: return cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
        case .month: return cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        case .allTime: return .distantPast
        }
    }
}
