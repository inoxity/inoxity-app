protocol SurveyEventUploadRepository: Sendable {
    func upload(_ event: SurveyEventUpload) async throws -> SurveyEventAcknowledgment
}
