import SwiftUI
import UIKit

// Shared with AppState.swift/SyncCoordinator.swift's own equivalent `Bundle.main.object(forInfoDictionaryKey:
// "CFBundleShortVersionString")` reads (kept private there for their own narrower purposes — sync
// payload / survey-event `app_version` fields) — this is the one place a human actually reads the
// version, so it's also the one place worth a real fallback string instead of "unknown".
private extension Bundle {
    var appVersionString: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    var appBuildNumber: String { object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
}

struct SettingsView: View {
    @EnvironmentObject private var state: AppState; let configuration: StudyConfiguration
    @State private var healthActionInProgress = false
    @State private var notificationActionInProgress = false
    @State private var editingSleepSchedule = false
    @State private var editingParticipantID = false
    // Collapsed by default — these three diagnostic cards plus app/device info are participant-
    // facing noise most of the time, but genuinely useful screenshotted and sent to the research
    // team when something's wrong, so they stay one tap away rather than disappearing entirely.
    @State private var diagnosticsExpanded = false
    var body: some View {
        InoxityScreen {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings").font(.system(.largeTitle, design: .rounded, weight: .light))
                SettingsCard(title: "STUDY", rows: [("Name", configuration.identity.displayName), ("Code", configuration.identity.code), (configuration.participantID.label, state.participantID)])
                SecondaryButton(title: "Edit \(configuration.participantID.label)") { editingParticipantID = true }
                SettingsCard(title: "INOXITY SUPPORT", rows: [("Contact", "Inoxity Team"), ("Email", "inoxity.team@gmail.com")])
                if configuration.sleepSchedule?.enabled == true { sleepScheduleSection }
                healthKitSection
                notificationSection
                surveySection
                mediaSection
                diagnosticsSection
                SecondaryButton(title: "Reset Enrollment") { state.beginWithdrawal() }
                Text("Starts the withdrawal flow so you can choose whether to keep or delete this study’s local data.")
                    .font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
            }
            .foregroundStyle(InoxityTheme.primaryText)
        }
        .sheet(isPresented: $editingSleepSchedule) {
            if let sleepSchedule = configuration.sleepSchedule {
                SleepScheduleView(configuration: sleepSchedule, progress: .init(current: 0, total: 1),
                                  savedWakeMinutes: state.participantState?.wakeTimeMinutes,
                                  savedBedMinutes: state.participantState?.bedTimeMinutes) { wakeMinutes, bedMinutes in
                    state.saveSleepSchedule(wakeMinutes: wakeMinutes, bedMinutes: bedMinutes)
                    editingSleepSchedule = false
                }
            }
        }
        .sheet(isPresented: $editingParticipantID) {
            EditParticipantIDView(configuration: configuration.participantID, currentValue: state.participantID) { value in
                state.saveParticipantID(value)
                editingParticipantID = false
            }
        }
    }

    // Collapses the three existing diagnostic cards (each still exactly what it always was —
    // reused unchanged here) plus app/device info into one disclosure so a participant's normal
    // Settings scroll stays short, while a research team asking "what does your app say?" still
    // gets a single row to tap that surfaces everything worth screenshotting.
    @ViewBuilder private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup("Diagnostics", isExpanded: $diagnosticsExpanded) {
                VStack(alignment: .leading, spacing: 20) {
                    SettingsCard(title: "APP", rows: [
                        ("Version", "\(Bundle.main.appVersionString) (\(Bundle.main.appBuildNumber))"),
                        ("OS", "iOS \(UIDevice.current.systemVersion)"),
                        ("Device", UIDevice.current.model),
                    ])
                    HealthKitUploadDiagnosticsView(configuration: configuration)
                    NotificationDiagnosticsView(configuration: configuration)
                    BackendDiagnosticsView()
                }
                .padding(.top, 10)
            }
            .font(.subheadline)
            .tint(InoxityTheme.aqua)
        }
    }

    @ViewBuilder private var sleepScheduleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SLEEP SCHEDULE").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(InoxityTheme.aqua)
            InoxityCard { VStack(alignment: .leading, spacing: 12) {
                settingsRow(configuration.sleepSchedule?.wakeLabel ?? "Wake time", timeText(state.participantState?.wakeTimeMinutes))
                settingsRow(configuration.sleepSchedule?.bedLabel ?? "Bed time", timeText(state.participantState?.bedTimeMinutes))
                Text("Survey and reminder times for this study are computed from your wake/bed time, so keep this up to date.")
                    .font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
                SecondaryButton(title: "Edit Sleep Schedule") { editingSleepSchedule = true }
            } }
        }
    }
    private func timeText(_ minutes: Int?) -> String {
        guard let minutes else { return "Not set" }
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    @ViewBuilder private var mediaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MEDIA").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(InoxityTheme.aqua)
            InoxityCard { VStack(alignment: .leading, spacing: 12) {
                settingsRow("Enabled for study", configuration.media.enabled ? "Yes" : "No")
                settingsRow("Categories", "\(configuration.media.categories.count)")
                settingsRow("Accepted types", configuration.media.acceptedTypes.map(\.rawValue.capitalized).joined(separator: ", "))
                settingsRow("Ready to upload", "\(state.mediaSummary.readyCount)")
                settingsRow("Upload failed", "\(state.mediaSummary.uploadFailedCount)")
                settingsRow("Local processing failed", "\(state.mediaSummary.failedCount)")
                settingsRow("Storage used", ByteCountFormatter.string(fromByteCount: state.mediaSummary.storageBytes, countStyle: .file))
                Text("Selected media uploads directly when you tap Upload and is not kept on this device afterward. Items shown here are still local, awaiting upload.")
                    .font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
                if let message = state.mediaErrorMessage { Text(message).font(.footnote).foregroundStyle(InoxityTheme.secondaryText) }
                SecondaryButton(title: "Refresh Media State") { state.refreshMediaRuntime() }
                if state.mediaSummary.failedCount > 0 { SecondaryButton(title: "Clear Failed Drafts") { state.clearFailedMediaDrafts() } }
            } }
        }
    }

    @ViewBuilder private var surveySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SURVEYS").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(InoxityTheme.aqua)
            InoxityCard {
                VStack(alignment: .leading, spacing: 12) {
                    settingsRow("Enabled for study", configuration.features.surveysEnabled ? "Yes" : "No")
                    settingsRow("Survey definitions", "\(configuration.surveys.filter(\.enabled).count)")
                    settingsRow("Available now", "\(state.surveySummary.availableCount)")
                    settingsRow("Completed recently", "\(state.surveySummary.completedCount)")
                    settingsRow("Missed recently", "\(state.surveySummary.missedCount)")
                    settingsRow("Completion callback", configuration.surveys.filter(\.enabled).allSatisfy(\.completionCallback.enabled) ? "Ready" : "Not used")
                    settingsRow("Presentation", presentationSummary)
                    settingsRow("Last completion", state.surveySummary.lastCompletionDate?.formatted(date: .abbreviated, time: .shortened) ?? "None")
                    if let message = state.surveyErrorMessage { Text(message).font(.footnote).foregroundStyle(InoxityTheme.secondaryText) }
                    SecondaryButton(title: "Refresh Survey Availability") { state.refreshSurveyRuntime() }
                    let available = state.surveySummary.occurrences.filter { $0.status.canStart }
                    if available.count == 1 {
                        SecondaryButton(title: "Open Current Survey") { state.requestSurveyStart(available[0].id) }
                    }
                }
            }
        }
    }

    private var presentationSummary: String {
        let modes = Set(configuration.surveys.filter(\.enabled).map(\.presentationMode))
        if modes.count > 1 { return "In-app and external" }
        return modes.first == .inAppBrowser ? "In-app browser" : modes.first == .externalBrowser ? "External browser" : "None"
    }

    @ViewBuilder private var notificationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NOTIFICATIONS").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(InoxityTheme.aqua)
            InoxityCard {
                VStack(alignment: .leading, spacing: 12) {
                    settingsRow("Enabled for study", configuration.notifications.enabled ? "Yes" : "No")
                    settingsRow("Enabled reminders", "\(configuration.reminders.filter(\.enabled).count)")
                    settingsRow("System status", nativeNotificationStatusText)
                    settingsRow("Request state", notificationRequestStateText)
                    settingsRow("Scheduled", "\(state.notificationPendingSummary.count)")
                    settingsRow("Next reminder", state.notificationPendingSummary.nextDate?.formatted(date: .abbreviated, time: .shortened) ?? "None")
                    settingsRow("Last reconciliation", state.participantState?.lastNotificationReconciliationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                    if configuration.notifications.enabled {
                        Text(configuration.notifications.rationale).font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
                        ForEach(configuration.reminders.filter(\.enabled)) { reminder in
                            Label(reminder.title, systemImage: reminder.kind == .survey ? "checklist" : "bell")
                                .font(.subheadline).foregroundStyle(InoxityTheme.primaryText)
                        }
                        Text(notificationStatusMessage).font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
                        if state.nativeNotificationStatus == .notDetermined {
                            SecondaryButton(title: notificationActionInProgress ? "Requesting…" : "Request Notifications") {
                                runNotification { await state.requestNotificationAccess() }
                            }.disabled(notificationActionInProgress)
                        }
                        SecondaryButton(title: "Refresh Notification Status") {
                            runNotification { await state.refreshNotificationStatus() }
                        }.disabled(notificationActionInProgress)
                        if [.authorized, .provisional, .ephemeral].contains(state.nativeNotificationStatus) {
                            SecondaryButton(title: notificationActionInProgress ? "Rescheduling…" : "Reschedule Reminders") {
                                runNotification { await state.reconcileNotifications(force: true) }
                            }.disabled(notificationActionInProgress)
                        }
                        if state.nativeNotificationStatus == .denied {
                            SecondaryButton(title: "Open System Settings") { state.openNotificationSystemSettings() }
                        }
                    } else {
                        Text("This study does not use local notifications.").font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
                    }
                }
            }
        }
    }

    @ViewBuilder private var healthKitSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("APPLE HEALTH").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(InoxityTheme.aqua)
            InoxityCard {
                VStack(alignment: .leading, spacing: 12) {
                    settingsRow("Available", state.healthKitAvailable ? "Yes" : "No")
                    settingsRow("Enabled for study", configuration.healthKit.enabled ? "Yes" : "No")
                    if configuration.healthKit.enabled {
                        settingsRow("Data types", healthTypeLabels)
                        settingsRow("Request state", requestStateText)
                        settingsRow("Last local sync", lastSyncText)
                        Text("Local See My Data summaries stay on this device. After enrollment, configured readable samples may sync only to this study’s verified Study Backend. Inoxity does not write to Apple Health, and deleted Apple Health samples are not yet mirrored remotely.")
                            .font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
                        Text(statusMessage).font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
                        if case .completedWithoutPrompt = state.healthKitStatus {
                            SecondaryButton(title: "Review in Health app") { state.openHealthApp() }
                        }
                        if state.healthKitAvailable, state.participantState?.healthKitRequestState != .requestCompleted {
                            SecondaryButton(title: healthActionInProgress ? "Requesting…" : "Request Access") {
                                run { await state.requestHealthKitAccess() }
                            }.disabled(healthActionInProgress)
                        }
                        if state.healthKitAvailable, state.participantState?.healthKitRequestState == .requestCompleted {
                            SecondaryButton(title: healthActionInProgress ? "Syncing…" : "Sync Now") {
                                run { await state.syncHealthKitNow() }
                            }.disabled(healthActionInProgress)
                        }
                        if case .syncSucceeded(let summary) = state.healthKitStatus {
                            ForEach(summary.metrics) { metric in settingsRow(metric.label, metric.value) }
                            Text("These values are a limited local summary of Apple Health data from the last seven days.")
                                .font(.caption).foregroundStyle(InoxityTheme.secondaryText)
                        }
                    } else {
                        Text("This study does not request Apple Health data.").font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
                    }
                }
            }
        }
    }

    private func settingsRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(label).foregroundStyle(InoxityTheme.secondaryText); Spacer(); Text(value).multilineTextAlignment(.trailing) }.font(.subheadline)
    }

    private var healthTypeLabels: String {
        configuration.healthKit.identifiers.compactMap { try? HealthKitTypeRegistry.type(for: $0).displayLabel }.joined(separator: ", ")
    }
    private var requestStateText: String {
        switch state.participantState?.healthKitRequestState ?? .notRequested {
        case .notRequested: "Not requested"
        case .requestCompleted: "Request completed"
        case .attentionNeeded: "Attention needed"
        }
    }
    private var lastSyncText: String {
        guard let date = state.participantState?.lastLocalSyncDate else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    private var statusMessage: String {
        switch state.healthKitStatus {
        case .notRequested: "Apple Health access has not been requested."
        case .requestCompleted: "The access request completed. Apple does not expose exact read authorization status."
        case .completedWithoutPrompt: "No new prompt appeared for this study — every requested data type already had a decision saved from a previous study or install. Use the Health app to review or change access for Inoxity."
        case .unavailable: "Apple Health is unavailable, but other study features remain available."
        case .attentionNeeded(let message): message
        case .syncing: "Reading a limited local Apple Health summary…"
        case .syncSucceeded: "Local Apple Health sync succeeded."
        case .syncFailed(let message): message
        }
    }
    private func run(_ action: @escaping () async -> Void) {
        healthActionInProgress = true
        Task { await action(); healthActionInProgress = false }
    }
    private func runNotification(_ action: @escaping () async -> Void) {
        notificationActionInProgress = true
        Task { await action(); notificationActionInProgress = false }
    }
    private var nativeNotificationStatusText: String {
        switch state.nativeNotificationStatus {
        case .notDetermined: "Not determined"
        case .denied: "Denied"
        case .authorized: "Authorized"
        case .provisional: "Provisional"
        case .ephemeral: "Ephemeral"
        case .unavailable: "Unavailable"
        }
    }
    private var notificationRequestStateText: String {
        switch state.participantState?.notificationPermissionState ?? .notRequested {
        case .notRequested: "Not requested"
        case .requestCompleted: "Request completed"
        case .attentionNeeded: "Attention needed"
        }
    }
    private var notificationStatusMessage: String {
        switch state.notificationStatus {
        case .notRequested: "Notification permission has not been requested."
        case .requesting: "Requesting notification permission…"
        case .requestCompleted: "The permission request completed."
        case .unavailable: "Notifications are unavailable."
        case .attentionNeeded(let value), .reconciliationFailed(let value): value
        case .scheduling: "Scheduling configured reminders…"
        case .scheduled(let count), .reconciliationSucceeded(let count): "\(count) reminders are scheduled for the current rolling horizon."
        case .noEnabledReminders: "No reminders are enabled."
        }
    }
}
private struct SettingsCard: View {
    let title: String, rows: [(String, String)]
    var body: some View { VStack(alignment: .leading, spacing: 10) { Text(title).font(.caption.weight(.semibold)).tracking(2).foregroundStyle(InoxityTheme.aqua); InoxityCard { VStack(spacing: 14) { ForEach(Array(rows.enumerated()), id: \.offset) { _, row in HStack(alignment: .top) { Text(row.0).foregroundStyle(InoxityTheme.secondaryText); Spacer(); Text(row.1).multilineTextAlignment(.trailing) }.font(.subheadline) } } } } }
}

/// Lets an already-enrolled participant correct their own participant/SONA ID from Settings —
/// e.g. a typo made during onboarding. Reuses the same `ParticipantIDValidator` onboarding's
/// `ParticipantIDView` validates against, so the format rules stay identical either way. Saving
/// updates local state immediately (the source of truth for what's shown in the app) and
/// best-effort syncs the correction to this study's Study Backend in the background
/// (`AppState.saveParticipantID` → `SyncCoordinating.syncParticipantIdentifier`) so the
/// researcher-facing record — e.g. what's used to match SONA course credit — doesn't stay stale.
private struct EditParticipantIDView: View {
    let configuration: ParticipantIDConfiguration
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value: String
    @State private var showError = false

    init(configuration: ParticipantIDConfiguration, currentValue: String, save: @escaping (String) -> Void) {
        self.configuration = configuration; self.save = save
        _value = State(initialValue: currentValue)
    }

    private var validation: ParticipantIDValidationResult { ParticipantIDValidator().validate(value, configuration: configuration) }
    private var valid: Bool { validation.value != nil }

    var body: some View {
        InoxityScreen {
            VStack(alignment: .leading, spacing: 20) {
                Text("Edit \(configuration.label)").font(.system(.largeTitle, design: .rounded, weight: .light))
                StyledTextField(label: configuration.label, placeholder: configuration.placeholder, text: $value)
                    .keyboardType(SONAIDValidator.applies(to: configuration) ? .numberPad : .default)
                Text(configuration.helpText).font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
                if showError && !valid, case .invalid(let message) = validation { ErrorMessageView(message: message) }
                PrimaryButton(title: "Save", isEnabled: valid) {
                    showError = true
                    guard valid else { return }
                    save(value)
                }
                SecondaryButton(title: "Cancel") { dismiss() }
            }.foregroundStyle(InoxityTheme.primaryText)
        }
    }
}
