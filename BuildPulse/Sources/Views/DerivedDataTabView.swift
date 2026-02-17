import ComposableArchitecture
import SwiftUI

struct DerivedDataTabView: View {
    @Bindable var store: StoreOf<AppFeature>

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
                    Button("Delete All", role: .destructive) {
                        store.send(.deleteAllTapped)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
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
                SizeBarView(projects: Array(store.sortedProjects.prefix(8)), total: store.totalDerivedDataSize)
                    .frame(height: 24)
            }

            // Project list
            ForEach(store.sortedProjects) { project in
                ProjectRow(
                    project: project,
                    isSelected: store.derivedDataSelection.contains(project.id),
                    onToggle: { store.send(.toggleProjectSelection(project.id)) },
                    onDelete: { store.send(.deleteProjectTapped(project)) }
                )
            }
        }
        .padding(16)
        .alert($store.scope(state: \.alert, action: \.alert))
    }
}

struct ProjectRow: View {
    let project: DerivedDataProject
    let isSelected: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)
                .onTapGesture { onToggle() }

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

    private let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .cyan, .yellow, .mint]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                    let fraction = total > 0 ? CGFloat(project.sizeBytes) / CGFloat(total) : 0
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colors[index % colors.count])
                        .frame(width: max(2, geo.size.width * fraction))
                        .help("\(project.name): \(project.sizeFormatted)")
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
