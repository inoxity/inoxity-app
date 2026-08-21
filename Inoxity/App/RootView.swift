import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @State private var minimumSplashDurationElapsed = false

    /// Held true until both the real restore (`state.isRestoring`) finishes AND a minimum
    /// wall-clock duration has elapsed, so the branded splash always reads as an intentional beat
    /// rather than a flash even when restore resolves instantly.
    private var showSplash: Bool { state.isRestoring || !minimumSplashDurationElapsed }

    var body: some View {
        ZStack {
            Group {
                if let study = state.configuration {
                    if state.onboardingComplete {
                        if state.showsPreStartWaiting, let startsOn = state.resolvedStartDate {
                            WaitingForStudyStartView(startsOn: startsOn)
                        } else if state.showsCompletionTakeover { StudyCompletionView(completion: study.completion) }
                        else {
                            MainTabView(
                                configuration: study, selection: $state.selectedTab,
                                isLockedAfterCompletion: state.isLockedAfterCompletion)
                        }
                    } else { OnboardingCoordinatorView(configuration: study) }
                } else if !state.isRestoring { StudyCodeView() }
            }
            if showSplash {
                SplashView().transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: showSplash)
        .task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            minimumSplashDurationElapsed = true
        }
        .sheet(item: $state.activeSurveyPresentation) { request in
            InAppSurveyView(request: request) { Task { await state.confirmInAppSurveyPresented(request.occurrenceID) } }
        }
        .sheet(isPresented: $state.withdrawalFlowPresented) { WithdrawalFlowView().environmentObject(state) }
        .sheet(item: $state.retainedEnrollmentConflict) { conflict in RetainedEnrollmentConflictView(conflict: conflict).environmentObject(state) }
    }
}
