import ComposableArchitecture
import SwiftUI
import UserNotifications

@main
struct BuildPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let store = Store(initialState: AppFeature.State()) { AppFeature() }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}

/// Separate view for the menu bar label to ensure reactive updates.
/// MenuBarExtra label closures may not re-evaluate with computed properties alone.
struct MenuBarLabel: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        let title = store.menuBarTitle
        if title.isEmpty {
            Label("BuildPulse", systemImage: "hammer.fill")
        } else {
            Label(title, systemImage: store.activeBuild != nil ? "hammer.fill" : "hammer.fill")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
