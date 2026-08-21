import Foundation

@MainActor
protocol HealthSummaryProviding: AnyObject {
    func snapshot(configuration: StudyConfiguration, participant: ParticipantState) async throws -> HealthSummarySnapshot
    func dailySnapshot(configuration: StudyConfiguration, participant: ParticipantState, day: Date, timeZone: TimeZone?) async throws -> DailyHealthSnapshot
}
