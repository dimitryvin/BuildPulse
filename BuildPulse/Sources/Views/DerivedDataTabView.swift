import ComposableArchitecture
import SwiftUI

struct DerivedDataTabView: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with total + actions
            HStack {
                VStack(alignment: .leading) {
                    Text("Total: \(ByteCountFormatter.string(fromByteCount: store.totalDerivedDataSize, countStyle: .file))")
                        .font(.headline)
                    Text("\(store.derivedDataProjects.count) projects")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Clean Up") {
                    Button("Delete selected (\(store.derivedDataSelection.count))") {
                        store.send(.deleteSelectedTapped)
                    }
                    .disabled(store.derivedDataSelection.isEmpty)
                    Divider()
                    Button("Delete older than 7 days") {
                        store.send(.deleteOlderThan(days: 7))
                    }
                    Button("Delete older than 30 days") {
                        store.send(.deleteOlderThan(days: 30))
                    }
                    Divider()
                    Button("Delete All") {
                        store.send(.deleteAllTapped)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(store.confirmingDelete != nil)
            }

            // Sort picker
            Picker("Sort", selection: Binding(
                get: { store.derivedDataSortOrder },
                set: { store.send(.sortOrderChanged($0)) }
            )) {
                ForEach(AppFeature.SortOrder.allCases, id: \.self) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.segmented)

            // Size bar visualization
            if !store.derivedDataProjects.isEmpty {
                SizeBarView(
                    projects: Array(store.sortedProjects.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(6)),
                    total: store.totalDerivedDataSize
                )
            }

            // Project list
            ForEach(store.sortedProjects) { project in
                ProjectRow(
                    project: project,
                    isSelected: store.derivedDataSelection.contains(project.id),
                    barColor: SizeBarView.color(for: project, in: store.derivedDataProjects),
                    onToggle: { store.send(.toggleProjectSelection(project.id)) },
                    onDelete: { store.send(.deleteProjectTapped(project)) }
                )
                .disabled(store.confirmingDelete != nil)
            }
        }
        .padding(16)
    }
}

// MARK: - Inline Confirmation Banner

struct DeleteConfirmationBanner: View {
    let confirmation: AppFeature.DeleteConfirmation
    let projects: [DerivedDataProject]
    let selectionCount: Int
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var message: String {
        switch confirmation {
        case let .project(project):
            return "Delete \(project.name) (\(project.sizeFormatted))?"
        case .selected:
            return "Delete \(selectionCount) selected projects?"
        case .all:
            return "Delete all \(projects.count) projects?"
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(message)
                .font(.callout.bold())
            Text("Xcode will rebuild on next build.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button("Delete") { onConfirm() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.red.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - Components

struct ProjectRow: View {
    let project: DerivedDataProject
    let isSelected: Bool
    let barColor: Color?
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)
                .onTapGesture { onToggle() }

            if let barColor {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor)
                    .frame(width: 3, height: 24)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .lineLimit(1)
                    .font(.callout)
                Text(project.lastModified, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text(project.sizeFormatted)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red.opacity(0.7))
        }
        .padding(.vertical, 2)
    }
}

struct SizeBarView: View {
    let projects: [DerivedDataProject]
    let total: Int64

    static let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .cyan, .yellow, .mint]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0.5) {
                ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                    let fraction = total > 0 ? CGFloat(project.sizeBytes) / CGFloat(total) : 0
                    if fraction > 0 {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Self.colors[index % Self.colors.count])
                            .frame(width: max(3, (geo.size.width - CGFloat(projects.count) * 0.5) * fraction))
                    }
                }
                // "Other" fills remaining space
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.gray.opacity(0.3))
            }
        }
        .frame(height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Color for a project based on its position in the size-sorted list
    static func color(for project: DerivedDataProject, in allProjects: [DerivedDataProject]) -> Color? {
        let sorted = allProjects.sorted { $0.sizeBytes > $1.sizeBytes }
        guard let index = sorted.prefix(colors.count).firstIndex(where: { $0.id == project.id }) else {
            return nil
        }
        return colors[index]
    }
}
