import SwiftUI

/// One-time full-screen takeover shown when `AppState.showsCompletionTakeover` is true — the
/// participant has crossed past their study's configured last day and hasn't yet acknowledged it.
/// Shown exactly once regardless of `appAccessRemainsAvailable`: Continue always dismisses it for
/// good (see `AppState.acknowledgeCompletionAndContinue()`), then either returns to the normal app
/// or — per that study's own setting — the app stays locked to Settings/About only from then on
/// (`MainTabView`'s `isLockedAfterCompletion`), so participants can still reach support/withdrawal.
struct StudyCompletionView: View {
    let completion: CompletionConfiguration
    @EnvironmentObject private var state: AppState
    @State private var isContinuing = false

    var body: some View {
        InoxityScreen {
            VStack(alignment: .leading, spacing: InoxityTheme.Spacing.extraLarge) {
                Spacer(minLength: 30)
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 52, weight: .thin))
                    .foregroundStyle(InoxityTheme.aqua)
                    .accessibilityHidden(true)
                Text(completion.title).font(.system(.largeTitle, design: .rounded, weight: .light))
                Text(completion.message).foregroundStyle(InoxityTheme.secondaryText).lineSpacing(5)
                Spacer(minLength: 20)
                PrimaryButton(title: isContinuing ? "Continuing…" : "Continue", isEnabled: !isContinuing) {
                    isContinuing = true
                    Task {
                        await state.acknowledgeCompletionAndContinue()
                        isContinuing = false
                    }
                }
            }
            .foregroundStyle(InoxityTheme.primaryText)
        }
    }
}
