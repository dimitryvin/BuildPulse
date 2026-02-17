import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showSizeInMenuBar") private var showSizeInMenuBar = true
    @AppStorage("alertThresholdGB") private var alertThresholdGB = 50.0
    @AppStorage("autoDeleteDays") private var autoDeleteDays = 0

    var body: some View {
        TabView {
            Form {
                Section("General") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                    Toggle("Show DerivedData size in menu bar", isOn: $showSizeInMenuBar)
                }

                Section("Alerts") {
                    HStack {
                        Text("Warn when DerivedData exceeds")
                        TextField("GB", value: $alertThresholdGB, format: .number)
                            .frame(width: 60)
                        Text("GB")
                    }
                }

                Section("Auto Cleanup") {
                    Picker("Auto-delete projects older than", selection: $autoDeleteDays) {
                        Text("Never").tag(0)
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                }

                Section("Data") {
                    HStack {
                        Text("Build records: \(appState.buildRecords.count)")
                        Spacer()
                        Button("Clear History") {
                            appState.buildRecords.removeAll()
                            appState.buildStore.save([])
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 450, height: 350)
    }
}
