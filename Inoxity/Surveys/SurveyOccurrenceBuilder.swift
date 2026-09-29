import Foundation

struct SurveyOccurrenceBuilder: Sendable {
    let policy: SurveyRuntimePolicy
    init(policy: SurveyRuntimePolicy = .default) { self.policy = policy }

    func build(configuration: StudyConfiguration, participant: ParticipantState, now: Date,
               timeZone: TimeZone? = nil, participantCollectionStart: Date? = nil,
               participantCollectionEnd: Date? = nil) throws -> [SurveyOccurrence] {
        guard StudyConfigurationValidator.supportedSchemaVersions.contains(configuration.schemaVersion) else {
            throw SurveyRuntimeError.unsupportedConfiguration
        }
        // Survey availability windows and wake/bed-anchored occurrence times are always computed
        // in the participant's own current local timezone (never the study's fixed
        // `schedule.timeZone`), matching NotificationScheduleBuilder's model.
        let timeZone = timeZone ?? .current
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let historyStart = calendar.date(byAdding: .day, value: -policy.historyDays, to: now) ?? now
        let futureEnd = calendar.date(byAdding: .day, value: policy.futureDays, to: now) ?? now
        let studyStart = date(configuration.schedule.startDate, calendar: calendar) ?? participant.enrollmentDate
        let studyEnd = endOfDay(configuration.schedule.endDate, calendar: calendar) ?? futureEnd
        // Same per-participant end as NotificationScheduleBuilder, so no survey occurs after the
        // participant's study is over.
        let durationEnd = StudyProgress.participantCollectionEnd(
            startDate: ParticipantStartDateResolver.resolve(schedule: configuration.schedule, participant: participant, calendar: calendar),
            participantDurationDays: configuration.schedule.participantDurationDays, calendar: calendar)
        let lower = [historyStart, participant.enrollmentDate, participantCollectionStart, studyStart].compactMap { $0 }.max() ?? historyStart
        let upper = [futureEnd, participantCollectionEnd, studyEnd, durationEnd].compactMap { $0 }.min() ?? futureEnd
        guard lower <= upper else { return [] }

        var result = [SurveyOccurrence](), seen = Set<String>()
        for survey in configuration.surveys where survey.enabled {
            let surveyLower = max(lower, date(survey.activeStartDate, calendar: calendar) ?? lower)
            let surveyUpper = min(upper, endOfDay(survey.activeEndDate, calendar: calendar) ?? upper)
            guard surveyLower <= surveyUpper else { continue }
            for scheduled in occurrences(schedule: survey.schedule, lower: surveyLower, upper: surveyUpper, calendar: calendar, participant: participant, studyID: configuration.identity.id, seedKey: survey.id) {
                let id = try SurveyOccurrenceIdentifierFactory.identifier(studyID: configuration.identity.id, surveyID: survey.id,
                                                                           occurrence: scheduled, calendar: calendar)
                guard seen.insert(id).inserted else { throw StudyConfigurationError.duplicateID(id) }
                let opens = calendar.date(byAdding: .minute, value: -survey.availabilityWindow.opensMinutesBefore, to: scheduled) ?? scheduled
                let closes = calendar.date(byAdding: .minute, value: survey.availabilityWindow.closesMinutesAfter, to: scheduled) ?? scheduled
                let persisted = participant.surveyOccurrenceStates[id]
                if let persisted, persisted.surveyID != survey.id || abs(persisted.scheduledFor.timeIntervalSince(scheduled)) >= 1 {
                    throw SurveyRuntimeError.inconsistentPersistedState
                }
                let status = status(now: now, opens: opens, closes: closes,
                                    persisted: persisted, eligible: participant.participationStatus == .enrolled)
                result.append(.init(id: id, studyID: configuration.identity.id, surveyID: survey.id,
                                    name: survey.name, summary: survey.description, instructions: survey.instructions,
                                    privacyText: survey.privacyText, presentationMode: survey.presentationMode,
                                    scheduledFor: scheduled, opensAt: opens, closesAt: closes,
                                    openedAt: persisted?.openedAt, completedAt: persisted?.completedAt, status: status))
            }
        }
        return result.sorted { $0.scheduledFor == $1.scheduledFor ? $0.id < $1.id : $0.scheduledFor < $1.scheduledFor }
    }

    // studyID/seedKey: unused by every pattern except `.randomWindow` — kept as a required
    // (not defaulted) pair of params for the same reason `NotificationScheduleBuilder`'s
    // equivalent does: currently no caller exists for this method (verified — it's unused
    // elsewhere in the app today), so there's no established convention to preserve either way,
    // but requiring the caller to be explicit avoids a future caller silently getting a
    // meaningless/empty seed for a `.randomWindow` schedule.
    func scheduledDates(for schedule: ReminderScheduleConfiguration, lower: Date, upper: Date,
                        timeZone: TimeZone = .current, participant: ParticipantState,
                        studyID: String, seedKey: String) -> [Date] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return occurrences(schedule: schedule, lower: lower, upper: upper, calendar: calendar, participant: participant, studyID: studyID, seedKey: seedKey)
    }

    /// The availability window (`opens`...`closes`) is the only rule: a survey can be opened and
    /// completed inside it and not outside it. `promptExpirationMinutes` is deliberately ignored.
    /// It only ever labelled occurrences on the phone (it never reaches the study's data), and
    /// counted from `opens` it blocked surveys hours before their notification arrived. Lateness
    /// can be computed from the uploaded `scheduled_for` and `opened_at` instead.
    private func status(now: Date, opens: Date, closes: Date, persisted: PersistedSurveyOccurrenceState?, eligible: Bool) -> SurveyOccurrenceStatus {
        if persisted?.completedAt != nil { return .completed }
        guard eligible else { return .unavailable }
        if now < opens { return .upcoming }
        if now > closes { return .missed }
        return persisted?.openedAt == nil ? .available : .opened
    }

    // studyID/seedKey: only consulted for `.randomWindow` schedules, to seed
    // `RandomWindowScheduling` deterministically — `seedKey` must be the survey's own `id` (see
    // that type's doc comment for why this must agree with whatever
    // `NotificationScheduleBuilder` seeds with when it resolves this same survey's schedule to
    // announce it via a linked reminder).
    private func occurrences(schedule: ReminderScheduleConfiguration, lower: Date, upper: Date, calendar: Calendar,
                             participant: ParticipantState, studyID: String, seedKey: String) -> [Date] {
        if schedule.pattern == .oneTime {
            guard let day = date(schedule.date, calendar: calendar), let value = occurrence(on: day, schedule: schedule, calendar: calendar, participant: participant),
                  value >= lower, value <= upper else { return [] }
            return [value]
        }
        if schedule.pattern == .randomWindow {
            var values = [Date](), day = calendar.startOfDay(for: lower)
            let final = calendar.startOfDay(for: upper)
            while day <= final {
                for value in RandomWindowScheduling.occurrences(on: day, schedule: schedule, calendar: calendar, studyID: studyID, seedKey: seedKey)
                where value >= lower && value <= upper {
                    values.append(value)
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            }
            return values
        }
        var values = [Date](), day = calendar.startOfDay(for: lower)
        let final = calendar.startOfDay(for: upper)
        while day <= final {
            let weekday = calendar.component(.weekday, from: day)
            if (schedule.pattern == .daily || schedule.weekdays.contains(weekday)),
               let value = occurrence(on: day, schedule: schedule, calendar: calendar, participant: participant), value >= lower, value <= upper {
                values.append(value)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return values
    }

    /// See `NotificationScheduleBuilder.occurrence(on:schedule:calendar:participant:)` — identical
    /// anchor-resolution rules, kept in sync so a survey's own availability window always lines up
    /// with the notification that announces it.
    private func occurrence(on day: Date, schedule: ReminderScheduleConfiguration, calendar: Calendar, participant: ParticipantState) -> Date? {
        switch schedule.resolvedAnchor {
        case .clockTime:
            return clockTimeOccurrence(on: day, hour: schedule.hour, minute: schedule.minute, calendar: calendar)
        case .wakeTime, .bedTime:
            let anchorMinutes = schedule.resolvedAnchor == .wakeTime ? participant.wakeTimeMinutes : participant.bedTimeMinutes
            guard let anchorMinutes, let base = clockTimeOccurrence(on: day, hour: anchorMinutes / 60, minute: anchorMinutes % 60, calendar: calendar) else { return nil }
            return calendar.date(byAdding: .minute, value: schedule.offsetMinutes ?? 0, to: base)
        }
    }

    private func clockTimeOccurrence(on day: Date, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        var values = calendar.dateComponents([.year, .month, .day], from: day)
        values.hour = hour; values.minute = minute
        if let exact = calendar.date(from: values) { return exact }
        return calendar.nextDate(after: calendar.startOfDay(for: day), matching: .init(hour: hour, minute: minute),
                                 matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }

    private func date(_ value: String?, calendar: Calendar) -> Date? {
        guard let value else { return nil }; let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: .init(year: parts[0], month: parts[1], day: parts[2]))
    }
    private func endOfDay(_ value: String?, calendar: Calendar) -> Date? {
        guard let start = date(value, calendar: calendar), let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return next.addingTimeInterval(-1)
    }
}
