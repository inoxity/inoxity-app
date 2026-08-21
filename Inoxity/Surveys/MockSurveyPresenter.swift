import Foundation

@MainActor
final class MockSurveyPresenter: SurveyPresenting {
    var error: Error?
    private(set) var requests = [SurveyPresentationRequest]()
    private(set) var openedURLs = [URL]()
    func openExternal(_ request: SurveyPresentationRequest) async throws {
        if let error { throw error }
        requests.append(request)
    }
    func open(url: URL) async throws {
        if let error { throw error }
        openedURLs.append(url)
    }
}
