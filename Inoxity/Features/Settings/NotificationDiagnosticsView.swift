import SwiftUI

struct NotificationDiagnosticsView: View {
    @EnvironmentObject private var state: AppState
    let configuration: StudyConfiguration
    @State private var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NOTIFICATION DIAGNOSTICS").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(InoxityTheme.aqua)
            InoxityCard { VStack(alignment: .leading, spacing: 12) {
                row("Authorization", label(state.notificationDiagnostics.authorizationStatus))
                row("Onboarding request", state.notificationDiagnostics.permissionRequestCompleted ? "Completed" : "Not completed")
                row("Configured reminders", "\(state.notificationDiagnostics.configuredReminderCount)")
                row("Pending requests", "\(state.notificationDiagnostics.pendingRequestCount)")
                row("Next fire date", state.notificationDiagnostics.nextFireDate?.formatted(date: .abbreviated, time: .shortened) ?? "None")
                row("Last reconciliation", state.notificationDiagnostics.lastReconciliationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                row("Result", state.notificationDiagnostics.lastReconciliationResult)
                row("Schedule configuration", state.notificationDiagnostics.fingerprintMatches ? "Current" : "Needs reconciliation")
                row("Survey reminders", state.notificationDiagnostics.surveyRemindersEnabled ? "Enabled" : "Disabled")
                row("Message reminders", state.notificationDiagnostics.messageRemindersEnabled ? "Enabled" : "Disabled")
                SecondaryButton(title: "Refresh Notification Status") { run { await state.refreshNotificationStatus(); await state.refreshNotificationDiagnostics() } }
                if [.authorized, .provisional, .ephemeral].contains(state.nativeNotificationStatus) {
                    SecondaryButton(title: "Reconcile Notifications") { run { await state.reconcileNotifications(force: true) } }
#if DEBUG
                    SecondaryButton(title: "Schedule Test Notification") { run { await state.scheduleTestNotification() } }
                    Text("The test alert fires in about 10 seconds and contains no participant data.").font(.caption).foregroundStyle(InoxityTheme.secondaryText)
#endif
                }
                if state.nativeNotificationStatus == .denied { SecondaryButton(title: "Open System Settings") { state.openNotificationSystemSettings() } }
            } }
        }.task { await state.refreshNotificationStatus(); await state.refreshNotificationDiagnostics() }
    }
    private func row(_ title: String, _ value: String) -> some View { HStack(alignment: .top) { Text(title).foregroundStyle(InoxityTheme.secondaryText); Spacer(); Text(value).multilineTextAlignment(.trailing) }.font(.subheadline) }
    private func run(_ action: @escaping () async -> Void) { working = true; Task { await action(); working = false } }
    private func label(_ value: NativeNotificationAuthorizationStatus) -> String {
        switch value { case .notDetermined: "Not determined"; case .denied: "Denied"; case .authorized: "Authorized"; case .provisional: "Provisional"; case .ephemeral: "Ephemeral"; case .unavailable: "Unavailable" }
    }
}
