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

/// Uses TimelineView to force re-render every second during active builds.
/// MenuBarExtra labels don't reliably react to TCA state observation alone.
struct MenuBarLabel: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let title = store.menuBarTitle
            if title.isEmpty {
                Label("BuildPulse", systemImage: "hammer.fill")
            } else {
                Label(title, systemImage: "hammer.fill")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
