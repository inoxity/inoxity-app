import SwiftUI

@main struct InoxityApp: App {
    @StateObject private var appState = AppState(container: .live)
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(appState).preferredColorScheme(.dark)
                .task { await appState.restoreEnrollment() }
                .onOpenURL { appState.handleOpenURL($0) }
                // Reminders/surveys are scheduled in the participant's current local timezone
                // (see NotificationScheduleBuilder/SurveyOccurrenceBuilder) — if that zone
                // changes (e.g. the participant travels), reconcile immediately rather than
                // waiting for the app to be foregrounded again. `Foundation` caches
                // `TimeZone.current` until `resetSystemTimeZone()` is called, so that must run
                // first or the reconciliation below would just recompute with the stale zone.
                .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                    NSTimeZone.resetSystemTimeZone()
                    Task { await appState.applicationDidBecomeActive() }
                }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await appState.applicationDidBecomeActive() } } }
    }
}
