import ComposableArchitecture
import SwiftUI

@main
struct BuildPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let store = Store(initialState: AppFeature.State()) { AppFeature() }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            Label(store.menuBarTitle, systemImage: "hammer.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permissions
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

import UserNotifications
