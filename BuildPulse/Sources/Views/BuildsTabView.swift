import SwiftUI

struct BuildsTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedRange: TimeRange = .week

    var filteredRecords: [BuildRecord] {
        appState.buildRecords.filter { $0.startTime >= selectedRange.startDate }
    }

    var dailyBuilds: [(String, Int, TimeInterval)] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        var grouped: [String: (count: Int, totalDuration: TimeInterval, date: Date)] = [:]
        for record in filteredRecords {
            let key = formatter.string(from: record.startTime)
            let existing = grouped[key] ?? (0, 0, record.startTime)
            grouped[key] = (existing.count + 1, existing.totalDuration + record.duration, record.startTime)
        }
        return grouped
            .sorted { $0.value.date < $1.value.date }
            .map { ($0.key, $0.value.count, $0.value.totalDuration) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Range", selection: $selectedRange) {
                ForEach(TimeRange.allCases, id: \.self) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let stats = appState.statsFor(range: selectedRange)

            // Stats summary
            HStack(spacing: 16) {
                StatCard(title: "Builds", value: "\(stats.totalBuilds)")
                StatCard(title: "Avg Time", value: stats.avgFormatted)
                StatCard(title: "Total Time", value: stats.totalFormatted)
                StatCard(title: "Success", value: stats.totalBuilds > 0 ? "\(Int(stats.successRate * 100))%" : "-")
            }

            // Simple bar chart
            if !dailyBuilds.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Builds per Day")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        BuildBarChart(data: dailyBuilds)
                            .frame(height: 80)
                    }
                }
            }

            // Build list
            GroupBox {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Build History")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if filteredRecords.isEmpty {
                        Text("No builds recorded yet")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(filteredRecords.prefix(20)) { record in
                            BuildRecordRow(record: record)
                        }
                    }
                }
            }

            if appState.buildRecords.count > 20 {
                Text("Showing 20 of \(filteredRecords.count) builds")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
    }
}

struct BuildBarChart: View {
    let data: [(String, Int, TimeInterval)]

    var maxCount: Int {
        data.map { $0.1 }.max() ?? 1
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(data.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 2) {
                    Text("\(item.1)")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.blue.gradient)
                        .frame(height: max(4, CGFloat(item.1) / CGFloat(maxCount) * 60))
                    Text(item.0)
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
