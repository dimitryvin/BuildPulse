import ComposableArchitecture
import SwiftUI

struct MenuBarView: View {
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("BuildPulse")
                    .font(.headline)
                Spacer()
                if store.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                }
                Button(action: { store.send(.refreshDerivedData) }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Tab picker
            Picker("", selection: $store.selectedTab.sending(\.tabSelected)) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()

            // Pinned delete confirmation (above scroll so always visible)
            if let confirmation = store.confirmingDelete {
                DeleteConfirmationBanner(
                    confirmation: confirmation,
                    projects: store.derivedDataProjects,
                    selectionCount: store.derivedDataSelection.count,
                    onConfirm: { store.send(.confirmDelete) },
                    onCancel: { store.send(.cancelDelete) }
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            // Content
            ScrollView {
                switch store.selectedTab {
                case .overview:
                    OverviewTabView(store: store)
                case .derivedData:
                    DerivedDataTabView(store: store)
                case .builds:
                    BuildsTabView(store: store)
                }
            }
            .frame(maxHeight: 400)

            Divider()

            // Footer
            HStack {
                SettingsLink {
                    Text("Settings...")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Spacer()
                Button("Quit") {
                    store.send(.quitButtonTapped)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 380)
        .onAppear { store.send(.onAppear) }
    }
}
