import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("BuildPulse")
                    .font(.headline)
                Spacer()
                if appState.isScanning {
                    ProgressView()
                        .scaleEffect(0.6)
                }
                Button(action: { Task { await appState.refreshDerivedData() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Tab picker
            Picker("", selection: $appState.selectedTab) {
                ForEach(AppState.Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()

            // Content
            ScrollView {
                switch appState.selectedTab {
                case .overview:
                    OverviewTabView()
                case .derivedData:
                    DerivedDataTabView()
                case .builds:
                    BuildsTabView()
                }
            }
            .frame(maxHeight: 400)

            Divider()

            // Footer
            HStack {
                Button("Settings...") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 380)
    }
}
