import Foundation

/// Drives the primary status line on the Home screen. Intentionally small: only states that are
/// reliably derivable from already-published app state are modeled here, rather than building a
/// general-purpose notification/status engine. Add a new case only when there's a concrete,
/// reliable app-state signal to back it — otherwise `.allSet` is always the safe default.
enum HomeStatus: Equatable {
    /// Health data access is required by the study but not currently granted. Checked ahead of
    /// `.surveyAvailable` since it's the more actionable/urgent state.
    case healthAccessNeeded
    /// At least one survey occurrence is currently open for this participant.
    case surveyAvailable
    /// Nothing needs the participant's attention right now.
    case allSet

    /// - Parameters:
    ///   - configuration: the active study configuration.
    ///   - healthKitRequestState: `ParticipantState.healthKitRequestState`, already kept in sync
    ///     elsewhere in the app (see `AppState`'s HealthKit reconciliation) — read here rather than
    ///     querying HealthKit authorization directly from the view.
    ///   - surveysAvailable: whether at least one survey occurrence is currently open, e.g.
    ///     `AppState.surveySummary.availableCount > 0`.
    static func current(configuration: StudyConfiguration, healthKitRequestState: HealthKitRequestState?, surveysAvailable: Bool) -> HomeStatus {
        if configuration.healthKit.enabled, healthKitRequestState == .attentionNeeded {
            return .healthAccessNeeded
        }
        if surveysAvailable {
            return .surveyAvailable
        }
        return .allSet
    }

    var title: String {
        switch self {
        case .allSet: "Everything's all set ✓"
        case .healthAccessNeeded: "Action needed"
        case .surveyAvailable: "Survey available"
        }
    }

    var message: String {
        switch self {
        case .allSet: "Inoxity is collecting the data enabled for your study."
        case .healthAccessNeeded: "Health data access is disabled. Enable it in Settings to keep your study data complete."
        case .surveyAvailable: "A survey is ready for you. Open the Surveys tab to complete it."
        }
    }
}
