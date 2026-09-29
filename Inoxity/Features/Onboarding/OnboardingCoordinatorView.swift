import SwiftUI

struct OnboardingCoordinatorView: View {
    @EnvironmentObject private var state: AppState; let configuration: StudyConfiguration
    private var pages: [OnboardingPage] { configuration.onboarding.pages.filter(\.enabled) }
    private var hasSleepSchedule: Bool { configuration.sleepSchedule?.enabled == true }
    private var needsStartDateStep: Bool { configuration.schedule.resolvedStartDateMode == .participantSelected }
    private var sleepScheduleStep: Int { pages.count + 2 }
    // Comes after the sleep-schedule step (if this study has one) and before Permissions — order
    // doesn't matter functionally (nothing downstream of onboarding depends on which of these two
    // ran first), this just keeps the two optional steps in a stable, predictable sequence.
    private var startDateStep: Int { pages.count + 2 + (hasSleepSchedule ? 1 : 0) }
    private var total: Int { pages.count + 3 + (hasSleepSchedule ? 1 : 0) + (needsStartDateStep ? 1 : 0) }
    var body: some View {
        let step = min(state.onboardingStep, total - 1)
        Group {
            if step == 0 { WelcomeView(configuration: configuration, progress: progress(step)) { advance(step) } }
            else if step <= pages.count { InformationPageView(page: pages[step - 1], progress: progress(step)) { advance(step) } }
            else if step == pages.count + 1 { ParticipantIDView(configuration: configuration.participantID, progress: progress(step)) { value in
                let success = await state.registerParticipantID(value)
                if success { advance(step) }
                return success
            } }
            else if hasSleepSchedule, step == sleepScheduleStep, let sleepSchedule = configuration.sleepSchedule {
                SleepScheduleView(configuration: sleepSchedule, progress: progress(step),
                                  savedWakeMinutes: state.participantState?.wakeTimeMinutes,
                                  savedBedMinutes: state.participantState?.bedTimeMinutes) { wakeMinutes, bedMinutes in
                    state.saveSleepSchedule(wakeMinutes: wakeMinutes, bedMinutes: bedMinutes)
                    advance(step)
                }
            }
            else if needsStartDateStep, step == startDateStep {
                ParticipantStartDateView(progress: progress(step)) { date in
                    // Writes to `ParticipantState.participantSelectedStartDate`, never
                    // `enrollmentDate` — see that property's doc comment for why the two must stay
                    // distinct.
                    state.saveParticipantSelectedStartDate(date)
                    advance(step)
                }
            }
            else { PermissionsOverviewView(configuration: configuration, progress: progress(step)) { state.finishOnboarding() } }
        }
    }
    private func progress(_ step: Int) -> OnboardingProgress { .init(current: step, total: total) }
    private func advance(_ step: Int) { state.saveOnboardingStep(step + 1) }
}

struct WelcomeView: View {
    let configuration: StudyConfiguration; let progress: OnboardingProgress; let continueAction: () -> Void
    var body: some View { OnboardingScreen(progress: progress) {
        InoxityLogo(); Spacer(minLength: 30)
        Image(systemName: configuration.onboarding.pages.first?.symbol ?? "sparkles").font(.system(size: 58, weight: .thin)).foregroundStyle(InoxityTheme.aqua).accessibilityHidden(true)
        Text(configuration.identity.shortName.uppercased()).font(.caption.weight(.semibold)).tracking(2).foregroundStyle(InoxityTheme.pink)
        Text(configuration.identity.welcomeTitle).font(.system(.largeTitle, design: .rounded, weight: .light))
        Text(configuration.identity.welcomeMessage).foregroundStyle(InoxityTheme.secondaryText).lineSpacing(5)
        PrimaryButton(title: "Get started", action: continueAction)
    } }
}
struct InformationPageView: View {
    let page: OnboardingPage; let progress: OnboardingProgress; let continueAction: () -> Void
    var body: some View { OnboardingScreen(progress: progress) {
        Image(systemName: page.symbol).font(.system(size: 52, weight: .thin)).foregroundStyle(InoxityTheme.aqua).accessibilityHidden(true)
        Text(page.title).font(.system(.largeTitle, design: .rounded, weight: .light))
        Text(page.body).foregroundStyle(InoxityTheme.secondaryText).lineSpacing(5)
        PrimaryButton(title: "Continue", action: continueAction)
    } }
}
struct ParticipantIDView: View {
    let configuration: ParticipantIDConfiguration; let progress: OnboardingProgress; let continueAction: (String) async -> Bool
    @EnvironmentObject private var state: AppState
    @State private var value = ""
    @State private var showError = false
    @State private var isRegistering = false
    @State private var lastAttemptFailed = false
    private var validation: ParticipantIDValidationResult { ParticipantIDValidator().validate(value, configuration: configuration) }
    private var valid: Bool { validation.value != nil }
    var body: some View { OnboardingScreen(progress: progress) {
        Text("IDENTIFY YOURSELF").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(InoxityTheme.aqua)
        Text(configuration.prompt).font(.system(.largeTitle, design: .rounded, weight: .light))
        StyledTextField(label: configuration.label, placeholder: configuration.placeholder, text: $value)
            .keyboardType(SONAIDValidator.applies(to: configuration) ? .numberPad : .default)
        Text(configuration.helpText).font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
        if showError && !valid, case .invalid(let message) = validation { ErrorMessageView(message: message) }
        if isRegistering, let message = state.backendActionMessage {
            Text(message).font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
        } else if lastAttemptFailed, let report = state.enrollmentErrorReport {
            EnrollmentErrorView(report: report, copyText: state.enrollmentErrorCopyText(report))
        } else if lastAttemptFailed, let message = state.backendActionMessage {
            ErrorMessageView(message: message)
        }
        PrimaryButton(title: isRegistering ? "Connecting…" : "Continue", isEnabled: valid && !isRegistering) {
            showError = true
            guard valid else { return }
            isRegistering = true
            Task {
                let success = await continueAction(value)
                isRegistering = false
                lastAttemptFailed = !success
            }
        }
    } }
}
/// Collects the participant's average wake time / bed time when a study's survey or reminder schedules
/// are anchored to them (`ScheduleAnchor.wakeTime`/`.bedTime`). Shown between the participant ID step
/// and the permissions overview; also reused from Settings so the participant can update it later.
struct SleepScheduleView: View {
    let configuration: SleepScheduleConfiguration
    let progress: OnboardingProgress
    let continueAction: (_ wakeMinutes: Int, _ bedMinutes: Int) -> Void
    @State private var wakeTime: Date
    @State private var bedTime: Date

    /// `savedWakeMinutes`/`savedBedMinutes`: the participant's current schedule, so editing it later
    /// (from Settings) starts from what they saved instead of resetting both pickers to 7:00/23:00.
    init(configuration: SleepScheduleConfiguration, progress: OnboardingProgress,
         savedWakeMinutes: Int? = nil, savedBedMinutes: Int? = nil,
         continueAction: @escaping (_ wakeMinutes: Int, _ bedMinutes: Int) -> Void) {
        self.configuration = configuration; self.progress = progress; self.continueAction = continueAction
        _wakeTime = State(initialValue: Self.time(minutes: savedWakeMinutes ?? 7 * 60))
        _bedTime = State(initialValue: Self.time(minutes: savedBedMinutes ?? 23 * 60))
    }

    private static func time(minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    var body: some View { OnboardingScreen(progress: progress) {
        Text("YOUR SCHEDULE").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(InoxityTheme.aqua)
        Text(configuration.promptTitle).font(.system(.largeTitle, design: .rounded, weight: .light))
        InoxityCard { VStack(alignment: .leading, spacing: 6) {
            Text(configuration.wakeLabel).font(.subheadline).foregroundStyle(InoxityTheme.secondaryText)
            DatePicker("", selection: $wakeTime, displayedComponents: .hourAndMinute).datePickerStyle(.wheel).labelsHidden()
        } }
        InoxityCard { VStack(alignment: .leading, spacing: 6) {
            Text(configuration.bedLabel).font(.subheadline).foregroundStyle(InoxityTheme.secondaryText)
            DatePicker("", selection: $bedTime, displayedComponents: .hourAndMinute).datePickerStyle(.wheel).labelsHidden()
        } }
        PrimaryButton(title: "Continue") { continueAction(minutesSinceMidnight(wakeTime), minutesSinceMidnight(bedTime)) }
    } }

    private func minutesSinceMidnight(_ date: Date) -> Int {
        let calendar = Calendar.current
        return calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }
}
/// Collects the participant's own confirmed real start date — only shown for studies with
/// `schedule.resolvedStartDateMode == .participantSelected` (see `ParticipantStartDateResolver`).
/// Defaults to today but can be moved to any date, including in the future (e.g. onboarding
/// happened ahead of the participant's actual scheduled start) — a future date holds the app on
/// `WaitingForStudyStartView` until it arrives.
struct ParticipantStartDateView: View {
    let progress: OnboardingProgress
    let continueAction: (Date) -> Void
    @State private var selectedDate = Date()

    var body: some View { OnboardingScreen(progress: progress) {
        Text("WHEN DO YOU BEGIN?").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(InoxityTheme.aqua)
        Text("Confirm your start date").font(.system(.largeTitle, design: .rounded, weight: .light))
        Text("Your day-in-study count is based on this date, not today — pick when your participation actually begins. If that's a future date, you'll see a waiting screen until it arrives.")
            .foregroundStyle(InoxityTheme.secondaryText).lineSpacing(5)
        InoxityCard {
            DatePicker("Start date", selection: $selectedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
        }
        PrimaryButton(title: "Continue") { continueAction(selectedDate) }
    } }
}
struct PermissionsOverviewView: View {
    @EnvironmentObject private var state: AppState
    let configuration: StudyConfiguration; let progress: OnboardingProgress; let continueAction: () -> Void
    @State private var requestingHealthAccess = false
    @State private var requestingNotifications = false
    var body: some View { OnboardingScreen(progress: progress) {
        Text("BEFORE YOU BEGIN").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(InoxityTheme.aqua)
        Text("Your permissions").font(.system(.largeTitle, design: .rounded, weight: .light))
        Text(configuration.healthKit.enabled ? "Choose whether to connect the Apple Health data configured for this study. You can continue either way." : "This study does not request Apple Health access. You can continue without connecting health data.").foregroundStyle(InoxityTheme.secondaryText)
        if configuration.healthKit.enabled { PermissionCard(symbol: "heart", title: "Health data", body: configuration.healthKit.rationale) }
        if configuration.notifications.enabled, configuration.reminders.contains(where: \.enabled) {
            PermissionCard(symbol: "bell", title: "Reminders", body: configuration.notifications.rationale)
        }
        if configuration.media.enabled { PermissionCard(symbol: configuration.media.acceptedTypes.contains(.photo) ? "photo" : "video", title: "Media", body: configuration.media.instructions) }
        if configuration.healthKit.enabled {
            if !state.healthKitAvailable {
                ErrorMessageView(message: "Apple Health is unavailable on this device. This does not prevent participation.")
            } else if case .notRequested = state.healthKitStatus {
                SecondaryButton(title: requestingHealthAccess ? "Requesting access…" : "Request Apple Health access") {
                    requestingHealthAccess = true
                    Task { await state.requestHealthKitAccess(); requestingHealthAccess = false }
                }
                .disabled(requestingHealthAccess)
            } else {
                Text(healthKitMessage).font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
                if case .completedWithoutPrompt = state.healthKitStatus {
                    SecondaryButton(title: "Review in Health app") { state.openHealthApp() }
                }
            }
        }
        if configuration.notifications.enabled, configuration.reminders.contains(where: \.enabled) {
            if case .notRequested = state.notificationStatus {
                SecondaryButton(title: requestingNotifications ? "Requesting notifications…" : "Request Notifications") {
                    requestingNotifications = true
                    Task { await state.requestNotificationAccess(); requestingNotifications = false }
                }.disabled(requestingNotifications)
            } else {
                Text(notificationMessage).font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
            }
        } else {
            Text("Notifications are not used for this study.").font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
        }
        PrimaryButton(title: "Enter study", action: continueAction)
    } }

    private var healthKitMessage: String {
        switch state.healthKitStatus {
        case .requestCompleted: "The Apple Health request was completed. Apple does not reveal exact read permission status."
        case .completedWithoutPrompt: "No new prompt appeared — you've already made a decision about this study's Apple Health data types in a previous study or install. Review or change access for Inoxity anytime in the Health app."
        case .attentionNeeded(let message), .syncFailed(let message): message
        case .unavailable: "Apple Health is unavailable."
        default: "You can manage Apple Health access later in Settings."
        }
    }
    private var notificationMessage: String {
        switch state.notificationStatus {
        case .requestCompleted, .scheduled(_), .reconciliationSucceeded(_): "The notification request completed. You can continue and manage reminders later in Settings."
        case .attentionNeeded(let message), .reconciliationFailed(let message): message
        case .unavailable: "Notifications are unavailable. This does not prevent participation."
        case .requesting: "Requesting notification access…"
        case .noEnabledReminders: "Notifications are not used for this study."
        default: "Notifications are optional."
        }
    }
}
private struct PermissionCard: View {
    let symbol: String, title: String, message: String
    init(symbol: String, title: String, body: String) { self.symbol = symbol; self.title = title; message = body }
    var body: some View { InoxityCard { HStack(alignment: .top, spacing: 16) { Image(systemName: symbol).foregroundStyle(InoxityTheme.aqua).frame(width: 28); VStack(alignment: .leading, spacing: 7) { Text(title).font(.headline); Text(message).font(.subheadline).foregroundStyle(InoxityTheme.secondaryText) } } } }
}
struct OnboardingScreen<Content: View>: View {
    let progress: OnboardingProgress; @ViewBuilder let content: Content
    var body: some View { InoxityScreen { VStack(alignment: .leading, spacing: 24) { progress; content }.foregroundStyle(InoxityTheme.primaryText) } }
}
