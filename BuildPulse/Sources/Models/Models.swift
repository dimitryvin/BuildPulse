import Foundation

// MARK: - DerivedData

struct DerivedDataProject: Identifiable, Comparable, Equatable, Sendable {
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

// MARK: - Build Records

struct BuildRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let scheme: String
    let project: String
    let startTime: Date
    let duration: TimeInterval
    let succeeded: Bool

    init(id: UUID = UUID(), scheme: String, project: String, startTime: Date, duration: TimeInterval, succeeded: Bool) {
        self.id = id
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

// MARK: - Build Stats

struct BuildStats: Equatable, Sendable {
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

// MARK: - Enums

enum TimeRange: String, CaseIterable, Equatable, Sendable {
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

enum Tab: String, CaseIterable, Equatable, Sendable {
    case overview = "Overview"
    case derivedData = "Derived Data"
    case builds = "Builds"
}

// MARK: - Build Events

enum BuildEvent: Equatable, Sendable {
    case buildStarted(project: String, startTime: Date)
    case buildFinished(project: String, duration: TimeInterval, succeeded: Bool)
}

// MARK: - Active Build

struct ActiveBuild: Equatable, Sendable {
    let project: String
    let startTime: Date
    var elapsedSeconds: Int = 0
}
