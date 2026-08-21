import UIKit

@MainActor
final class SurveyPresenter: SurveyPresenting {
    nonisolated init() {}
    func openExternal(_ request: SurveyPresentationRequest) async throws {
        guard await UIApplication.shared.open(request.url) else { throw SurveyRuntimeError.presentationFailed }
    }
    func open(url: URL) async throws {
        guard await UIApplication.shared.open(url) else { throw SurveyRuntimeError.presentationFailed }
    }
}
