import SwiftUI

struct OverviewTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedRange: TimeRange = .today

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Active build banner
            if let build = appState.activeBuild {
                ActiveBuildBanner(build: build)
            }

            // DerivedData summary
            GroupBox {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Derived Data")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: appState.totalDerivedDataSize, countStyle: .file))
                            .font(.title2.bold())
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Projects")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(appState.derivedDataProjects.count)")
                            .font(.title2.bold())
                    }
                }
            }

            // Build stats
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Range", selection: $selectedRange) {
                        ForEach(TimeRange.allCases, id: \.self) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    let stats = appState.statsFor(range: selectedRange)
                    HStack(spacing: 16) {
                        StatCard(title: "Builds", value: "\(stats.totalBuilds)")
                        StatCard(title: "Avg Time", value: stats.avgFormatted)
                        StatCard(title: "Total", value: stats.totalFormatted)
                        StatCard(title: "Success", value: stats.totalBuilds > 0 ? "\(Int(stats.successRate * 100))%" : "-")
                    }
                }
            }

            // Recent builds
            if !appState.buildRecords.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent Builds")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(appState.buildRecords.prefix(5)) { record in
                            BuildRecordRow(record: record)
                        }
                    }
                }
            }

            // Top projects by size
            if !appState.derivedDataProjects.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Largest Projects")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(appState.derivedDataProjects.prefix(3)) { project in
                            HStack {
                                Text(project.name)
                                    .lineLimit(1)
                                Spacer()
                                Text(project.sizeFormatted)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
        .padding(16)
    }
}

struct ActiveBuildBanner: View {
    let build: ActiveBuild
    @State private var elapsed: TimeInterval = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            Image(systemName: "hammer.fill")
                .foregroundStyle(.orange)
                .symbolEffect(.pulse)
            Text("Building \(build.project)")
                .lineLimit(1)
            Spacer()
            Text("\(Int(elapsed))s")
                .monospacedDigit()
                .foregroundStyle(.orange)
        }
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .onReceive(timer) { _ in
            elapsed = Date().timeIntervalSince(build.startTime)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct BuildRecordRow: View {
    let record: BuildRecord

    var body: some View {
        HStack {
            Circle()
                .fill(record.succeeded ? .green : .red)
                .frame(width: 6, height: 6)
            Text(record.project)
                .lineLimit(1)
            Spacer()
            Text(record.durationFormatted)
                .foregroundStyle(.secondary)
            Text(record.startTime, style: .time)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
    }
}
