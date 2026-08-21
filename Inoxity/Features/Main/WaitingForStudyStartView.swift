import SwiftUI

/// Shown in place of the normal post-onboarding app whenever `AppState.showsPreStartWaiting` is
/// true — the participant finished onboarding, but their resolved start date (see
/// `ParticipantStartDateResolver`) is still in the future, so day-in-study math doesn't apply yet.
/// Reachable only under `StartDateMode.fixed`/`.participantSelected` — `.enrollment`'s start date
/// is stamped at enrollment itself and so can never be in the future. RootView re-evaluates this on
/// every state change, so the app transitions on its own to the normal `MainTabView` the moment the
/// date arrives — no action needed here, unlike `StudyCompletionView`'s explicit "Continue".
struct WaitingForStudyStartView: View {
    let startsOn: Date
    @Environment(\.calendar) private var calendar

    private var daysUntilStart: Int {
        let today = calendar.startOfDay(for: Date())
        let start = calendar.startOfDay(for: startsOn)
        return max(1, calendar.dateComponents([.day], from: today, to: start).day ?? 1)
    }

    private var startDateText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.calendar = calendar
        return formatter.string(from: startsOn)
    }

    var body: some View {
        InoxityScreen {
            VStack(alignment: .leading, spacing: InoxityTheme.Spacing.extraLarge) {
                Spacer(minLength: 30)
                Image(systemName: "hourglass")
                    .font(.system(size: 52, weight: .thin))
                    .foregroundStyle(InoxityTheme.aqua)
                    .accessibilityHidden(true)
                Text("Your study hasn't started yet")
                    .font(.system(.largeTitle, design: .rounded, weight: .light))
                Text(daysUntilStart == 1
                     ? "Your study begins tomorrow, \(startDateText)."
                     : "Your study begins in \(daysUntilStart) days, on \(startDateText).")
                    .foregroundStyle(InoxityTheme.secondaryText)
                    .lineSpacing(5)
                Text("You're all set — there's nothing else to do right now. Come back on your start date to begin.")
                    .foregroundStyle(InoxityTheme.secondaryText)
                    .lineSpacing(5)
                Spacer(minLength: 20)
            }
            .foregroundStyle(InoxityTheme.primaryText)
        }
    }
}
