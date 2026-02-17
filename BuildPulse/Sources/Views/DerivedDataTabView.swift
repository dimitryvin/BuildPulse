import SwiftUI

struct DerivedDataTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection = Set<String>()
    @State private var sortOrder: SortOrder = .size
    @State private var showConfirmDelete = false
    @State private var projectToDelete: DerivedDataProject?

    enum SortOrder: String, CaseIterable {
        case size = "Size"
        case name = "Name"
        case modified = "Last Modified"
    }

    var sortedProjects: [DerivedDataProject] {
        switch sortOrder {
        case .size: return appState.derivedDataProjects.sorted { $0.sizeBytes > $1.sizeBytes }
        case .name: return appState.derivedDataProjects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .modified: return appState.derivedDataProjects.sorted { $0.lastModified > $1.lastModified }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with total + actions
            HStack {
                VStack(alignment: .leading) {
                    Text("Total: \(ByteCountFormatter.string(fromByteCount: appState.totalDerivedDataSize, countStyle: .file))")
                        .font(.headline)
                    Text("\(appState.derivedDataProjects.count) projects")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Clean Up") {
                    Button("Delete selected (\(selection.count))") {
                        showConfirmDelete = true
                    }
                    .disabled(selection.isEmpty)
                    Divider()
                    Button("Delete older than 7 days") {
                        Task {
                            let old = appState.derivedDataProjects.filter {
                                $0.lastModified < Calendar.current.date(byAdding: .day, value: -7, to: Date())!
                            }
                            await appState.deleteProjects(old)
                        }
                    }
                    Button("Delete older than 30 days") {
                        Task {
                            let old = appState.derivedDataProjects.filter {
                                $0.lastModified < Calendar.current.date(byAdding: .day, value: -30, to: Date())!
                            }
                            await appState.deleteProjects(old)
                        }
                    }
                    Divider()
                    Button("Delete All", role: .destructive) {
                        Task { await appState.deleteProjects(appState.derivedDataProjects) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // Sort picker
            Picker("Sort", selection: $sortOrder) {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.segmented)

            // Size bar visualization
            if !appState.derivedDataProjects.isEmpty {
                SizeBarView(projects: Array(sortedProjects.prefix(8)), total: appState.totalDerivedDataSize)
                    .frame(height: 24)
            }

            // Project list
            ForEach(sortedProjects) { project in
                ProjectRow(project: project, isSelected: selection.contains(project.id)) {
                    if selection.contains(project.id) {
                        selection.remove(project.id)
                    } else {
                        selection.insert(project.id)
                    }
                } onDelete: {
                    projectToDelete = project
                    showConfirmDelete = true
                }
            }
        }
        .padding(16)
        .alert("Delete Derived Data?", isPresented: $showConfirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    if let project = projectToDelete {
                        await appState.deleteProject(project)
                        projectToDelete = nil
                    } else {
                        let toDelete = appState.derivedDataProjects.filter { selection.contains($0.id) }
                        await appState.deleteProjects(toDelete)
                        selection.removeAll()
                    }
                }
            }
        } message: {
            if let project = projectToDelete {
                Text("Remove \(project.name) (\(project.sizeFormatted))? Xcode will rebuild on next build.")
            } else {
                Text("Remove \(selection.count) projects? Xcode will rebuild them on next build.")
            }
        }
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
