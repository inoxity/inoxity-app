import Foundation

enum SurveyCompletionValidator {
    static func validate(record: PersistedSurveyOccurrenceState, occurrence: SurveyOccurrence,
                         receivedAt: Date, policy: SurveyCompletionPolicy) throws {
        guard record.occurrenceID == occurrence.id, record.surveyID == occurrence.surveyID,
              abs(record.scheduledFor.timeIntervalSince(occurrence.scheduledFor)) < 1 else {
            throw SurveyRuntimeError.inconsistentPersistedState
        }
        guard let opened = record.openedAt else { throw SurveyRuntimeError.occurrenceNotOpened }
        guard opened >= occurrence.opensAt, opened <= occurrence.closesAt else { throw SurveyRuntimeError.invalidOpenedTimeline }
        guard receivedAt >= opened else { throw SurveyRuntimeError.callbackBeforeOpen }
        let deadline = occurrence.closesAt.addingTimeInterval(TimeInterval(policy.callbackGraceMinutes * 60))
        guard receivedAt <= deadline else { throw SurveyRuntimeError.callbackExpired }
    }
}
