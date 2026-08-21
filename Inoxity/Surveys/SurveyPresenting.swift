import Foundation

@MainActor
protocol SurveyPresenting: AnyObject {
    func openExternal(_ request: SurveyPresentationRequest) async throws
    /// Opens an arbitrary URL externally — used by `AppState.acknowledgeCompletionAndContinue()`
    /// for `CompletionConfiguration.redirectURL`, which (unlike a survey) has no occurrence to
    /// attach to `SurveyPresentationRequest`. Kept on this same protocol rather than calling
    /// `UIApplication.shared.open` directly from AppState, so it stays covered by the existing
    /// `MockSurveyPresenter` test seam.
    func open(url: URL) async throws
}
