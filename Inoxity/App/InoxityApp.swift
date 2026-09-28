import SwiftUI

@main struct InoxityApp: App {
    @UIApplicationDelegateAdaptor(InoxityAppDelegate.self) private var appDelegate
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

/// HealthKit requires observer queries to be re-registered in didFinishLaunching on every launch —
/// including background launches HealthKit itself triggers to deliver new samples, where the
/// SwiftUI view tree (and so AppState) may never be built. See HealthKitBackgroundDelivery.
final class InoxityAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppContainer.live.healthKitBackgroundDelivery?.resumePersistedObservation()
        return true
    }
}
