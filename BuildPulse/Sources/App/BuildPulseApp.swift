import ComposableArchitecture
import SwiftUI
import UserNotifications

@main
struct BuildPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let store = Store(initialState: AppFeature.State()) { AppFeature() }

    init() {
        // Start monitoring immediately at launch, not when the popover first opens
        store.send(.onAppear)
    }

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

/// Separate view to ensure SwiftUI re-evaluates when TCA state changes.
/// The timerTicked action updates elapsedSeconds, which changes menuBarTitle,
/// which triggers SwiftUI to re-render this view.
struct MenuBarLabel: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        let title = store.menuBarTitle
        if title.isEmpty {
            Label("BuildPulse", systemImage: "hammer.fill")
        } else {
            Label(title, systemImage: "hammer.fill")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
