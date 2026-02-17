import ComposableArchitecture
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let store: StoreOf<AppFeature>
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showSizeInMenuBar") private var showSizeInMenuBar = true
    @AppStorage("alertThresholdGB") private var alertThresholdGB = 50.0
    @AppStorage("autoDeleteDays") private var autoDeleteDays = 0
    @AppStorage("notifyOnBuildComplete") private var notifyOnBuildComplete = false

    var body: some View {
        TabView {
            Form {
                Section("General") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                launchAtLogin = !newValue
                            }
                        }
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

                Section("Notifications") {
                    Toggle("Notify when build completes", isOn: $notifyOnBuildComplete)
                }

                Section("Data") {
                    HStack {
                        Text("Build records: \(store.buildRecords.count)")
                        Spacer()
                        Button("Clear History") {
                            store.send(.clearBuildHistory)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 450, height: 400)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
