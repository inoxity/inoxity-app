import Foundation

struct SurveyRuntimePolicy: Equatable, Sendable {
    let historyDays: Int
    let futureDays: Int
    static let `default` = SurveyRuntimePolicy(historyDays: 30, futureDays: 30)
}

struct SurveyConfigurationPolicy: Equatable, Sendable {
    let maximumOpensMinutesBefore: Int
    let maximumClosesMinutesAfter: Int
    let maximumNotificationOffsetMinutes: Int
    static let `default` = SurveyConfigurationPolicy(
        maximumOpensMinutesBefore: 1_440,
        maximumClosesMinutesAfter: 1_440,
        maximumNotificationOffsetMinutes: 1_440
    )
}

struct SurveyCompletionPolicy: Equatable, Sendable {
    let callbackGraceMinutes: Int
    static let `default` = SurveyCompletionPolicy(callbackGraceMinutes: 60)
}
