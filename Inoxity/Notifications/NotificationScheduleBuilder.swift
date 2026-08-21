import Foundation

struct NotificationScheduleBuilder: Sendable {
    let policy: NotificationSchedulingPolicy

    init(policy: NotificationSchedulingPolicy = .default) { self.policy = policy }

    func build(configuration: StudyConfiguration, participant: ParticipantState, now: Date,
               timeZone: TimeZone? = nil, participantCollectionStart: Date? = nil,
               participantCollectionEnd: Date? = nil) throws -> NotificationSchedulePlan {
        // Wall-clock times are always computed in the participant's own current local
        // timezone (never the study's fixed `schedule.timeZone`) so reminders fire at the
        // right local time wherever the participant actually is, and follow them if they travel.
        let timeZone = timeZone ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let fingerprint = fingerprint(configuration: configuration, participant: participant, timeZone: timeZone)
        guard StudyConfigurationValidator.supportedSchemaVersions.contains(configuration.schemaVersion) else { return emptyPlan(fingerprint: fingerprint) }
        guard configuration.notifications.enabled,
              configuration.status.state == .active,
              participant.participationStatus == .enrolled else {
            return emptyPlan(fingerprint: fingerprint)
        }

        let horizonEnd = calendar.date(byAdding: .day, value: policy.rollingHorizonDays, to: now) ?? now
        // Consults the participant's own resolved start date (see `ParticipantStartDateResolver`)
        // — not just `configuration.schedule.startDate` — so a `.fixed`/`.participantSelected`
        // study never schedules a notification before that date, including when it's in the
        // future (a `.participantSelected` participant who confirmed a start date next week).
        let studyStart = ParticipantStartDateResolver.resolve(schedule: configuration.schedule, participant: participant, calendar: calendar)
            ?? date(configuration.schedule.startDate, calendar: calendar) ?? participant.enrollmentDate
        let studyEnd = endOfDay(configuration.schedule.endDate, calendar: calendar) ?? horizonEnd
        let lower = [now, participant.enrollmentDate, participantCollectionStart, studyStart].compactMap { $0 }.max() ?? now
        let upper = [horizonEnd, participantCollectionEnd, studyEnd].compactMap { $0 }.min() ?? horizonEnd
        guard lower <= upper else { return emptyPlan(fingerprint: fingerprint) }

        let enabledSurveyIDs = Set(configuration.surveys.filter(\.enabled).map(\.id))
        var generated = [ScheduledNotification]()
        for reminder in configuration.reminders where reminder.enabled {
            var surveyConfiguration: SurveyConfiguration?
            if reminder.kind == .survey {
                guard let surveyID = reminder.surveyID, enabledSurveyIDs.contains(surveyID),
                      let survey = configuration.surveys.first(where: { $0.id == surveyID }) else { continue }
                surveyConfiguration = survey
            }
            let reminderLower = max(lower, date(reminder.activeStartDate, calendar: calendar) ?? lower)
            let reminderUpper = min(upper, endOfDay(reminder.activeEndDate, calendar: calendar) ?? upper)
            guard reminderLower <= reminderUpper else { continue }
            let scheduledPairs: [(fire: Date, surveyOccurrence: Date?)]
            if configuration.schemaVersion >= 4, let survey = surveyConfiguration, let offset = reminder.notifyMinutesBefore {
                // Seeded by survey.id, not reminder.id — this resolves the SURVEY's own schedule
                // (a linked reminder just announces it), so a randomWindow survey must randomize
                // identically here and in SurveyOccurrenceBuilder, which has no reminder.id to seed
                // with at all. Seeding by reminder.id here would compute a different random draw
                // than the survey's own actual occurrence time, producing a notification for a
                // moment the survey never opens at and an occurrence ID SurveyOccurrenceBuilder
                // would never itself generate (unknownOccurrence on tap).
                let dates = occurrences(for: survey.schedule, lower: reminderLower, upper: reminderUpper, calendar: calendar, participant: participant, studyID: configuration.identity.id, seedKey: survey.id)
                scheduledPairs = dates.compactMap { scheduled in
                    guard let fire = calendar.date(byAdding: .minute, value: -offset, to: scheduled), fire >= lower, fire <= upper else { return nil }
                    return (fire, scheduled)
                }
            } else if let schedule = reminder.schedule {
                let fires = occurrences(for: schedule, lower: reminderLower, upper: reminderUpper, calendar: calendar, participant: participant, studyID: configuration.identity.id, seedKey: reminder.id)
                if let survey = surveyConfiguration {
                    scheduledPairs = fires.compactMap { fire in
                        let dayStart = calendar.startOfDay(for: fire)
                        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)?.addingTimeInterval(-1) ?? fire
                        // Same seed-key correction as above — resolving survey.schedule, so seed by survey.id.
                        let surveyDate = occurrences(for: survey.schedule, lower: dayStart, upper: dayEnd, calendar: calendar, participant: participant, studyID: configuration.identity.id, seedKey: survey.id).first
                        return surveyDate.map { (fire, $0) }
                    }
                } else { scheduledPairs = fires.map { ($0, nil) } }
            } else { scheduledPairs = [] }
            for pair in scheduledPairs {
                let occurrence = pair.fire
                let identifier = NotificationIdentifierFactory.identifier(studyID: configuration.identity.id,
                                                                         reminderID: reminder.id, occurrence: occurrence,
                                                                         calendar: calendar)
                let occurrenceID: String
                if let survey = surveyConfiguration, let surveyDate = pair.surveyOccurrence {
                    occurrenceID = try SurveyOccurrenceIdentifierFactory.identifier(studyID: configuration.identity.id,
                                                                                     surveyID: survey.id, occurrence: surveyDate,
                                                                                     calendar: calendar)
                } else { occurrenceID = identifier.split(separator: ".").last.map(String.init) ?? identifier }
                generated.append(ScheduledNotification(
                    identifier: identifier, fireDate: occurrence, title: reminder.title, body: reminder.body,
                    payload: NotificationPayload(studyID: configuration.identity.id, reminderID: reminder.id,
                                                 notificationKind: reminder.kind, surveyID: reminder.surveyID,
                                                 occurrenceID: occurrenceID, destination: reminder.destination),
                    timeZoneIdentifier: timeZone.identifier
                ))
            }
        }
        // Surveys that opt in via `sendNotificationOnOpen` get their own-open notification
        // generated directly here, at the survey's own schedule times — no `ReminderConfiguration`
        // needs to exist for them. If an enabled kind == .survey reminder already targets this
        // survey, that explicit reminder wins (the researcher made an intentional choice for it,
        // e.g. a specific notifyMinutesBefore lead time) and this auto-notification is skipped to
        // avoid double-notifying the same occurrence. Reuses the same `notificationKind: .survey`
        // / `destination: .surveys` shape as a linked reminder, so routing, the survey action
        // buttons, and snoozing all work identically without any of that code needing to change.
        let manuallyLinkedSurveyIDs = Set(configuration.reminders.filter { $0.enabled && $0.kind == .survey }.compactMap(\.surveyID))
        for survey in configuration.surveys where survey.enabled && survey.sendNotificationOnOpen && !manuallyLinkedSurveyIDs.contains(survey.id) {
            let surveyLower = max(lower, date(survey.activeStartDate, calendar: calendar) ?? lower)
            let surveyUpper = min(upper, endOfDay(survey.activeEndDate, calendar: calendar) ?? upper)
            guard surveyLower <= surveyUpper else { continue }
            let reminderID = "__survey_open__.\(survey.id)"
            // Seeded by survey.id (not the synthesized reminderID above, which is only used for the
            // notification's own identifier/payload) — same reasoning as the two call sites above:
            // this resolves the survey's own schedule, so it must randomize identically to what
            // SurveyOccurrenceBuilder computes for that survey.
            let occurrenceDates = occurrences(for: survey.schedule, lower: surveyLower, upper: surveyUpper, calendar: calendar, participant: participant, studyID: configuration.identity.id, seedKey: survey.id)
            for occurrence in occurrenceDates {
                let identifier = NotificationIdentifierFactory.identifier(studyID: configuration.identity.id,
                                                                         reminderID: reminderID, occurrence: occurrence,
                                                                         calendar: calendar)
                let occurrenceID = try SurveyOccurrenceIdentifierFactory.identifier(studyID: configuration.identity.id,
                                                                                     surveyID: survey.id, occurrence: occurrence,
                                                                                     calendar: calendar)
                generated.append(ScheduledNotification(
                    identifier: identifier, fireDate: occurrence,
                    title: survey.notificationTitle ?? "\(survey.name) is available",
                    body: survey.notificationBody ?? "Tap to open it now.",
                    payload: NotificationPayload(studyID: configuration.identity.id, reminderID: reminderID,
                                                 notificationKind: .survey, surveyID: survey.id,
                                                 occurrenceID: occurrenceID, destination: .surveys),
                    timeZoneIdentifier: timeZone.identifier
                ))
            }
        }
        generated.sort { $0.fireDate == $1.fireDate ? $0.identifier < $1.identifier : $0.fireDate < $1.fireDate }
        var seen = Set<String>()
        for request in generated where !seen.insert(request.identifier).inserted {
            throw NotificationServiceError.duplicateIdentifier(request.identifier)
        }
        let scheduled = Array(generated.prefix(policy.maximumPendingRequestsPerStudy))
        return NotificationSchedulePlan(requests: scheduled, generatedOccurrenceCount: generated.count,
                                        scheduledOccurrenceCount: scheduled.count,
                                        omittedOccurrenceCount: generated.count - scheduled.count,
                                        wasTruncated: generated.count > scheduled.count, fingerprint: fingerprint)
    }

    func fingerprint(configuration: StudyConfiguration, participant: ParticipantState, timeZone: TimeZone? = nil) -> String {
        let timeZone = timeZone ?? .current
        let reminderText = configuration.reminders.map { reminder in
            let schedule = reminder.schedule
            let weekdays = schedule?.weekdays.map { String($0) }.joined(separator: ",") ?? ""
            let fields: [String] = [reminder.id, reminder.kind.rawValue, String(reminder.enabled), reminder.title,
                                    reminder.body, reminder.surveyID ?? "", schedule?.pattern.rawValue ?? "",
                                    schedule?.date ?? "", String(schedule?.hour ?? -1), String(schedule?.minute ?? -1),
                                    weekdays, String(reminder.notifyMinutesBefore ?? -1), reminder.destination.rawValue,
                                    reminder.activeStartDate ?? "", reminder.activeEndDate ?? "",
                                    (schedule?.resolvedAnchor ?? .clockTime).rawValue, String(schedule?.offsetMinutes ?? -1),
                                    String(schedule?.windowCount ?? -1), String(schedule?.windowStartHour ?? -1),
                                    String(schedule?.windowLengthHours ?? -1)]
            return fields.joined(separator: "|")
        }.joined(separator: "||")
        // Includes the full schedule shape (not just anchor/offset — also the randomWindow fields
        // and promptExpirationMinutes, both of which live here now) plus the auto-notification
        // fields, so toggling `sendNotificationOnOpen` or editing any of this in the dashboard
        // reliably changes the fingerprint and triggers a reschedule on-device. Split into two
        // sub-arrays (rather than one long literal) — the compiler can't type-check a single
        // array literal this long in reasonable time.
        let surveyScheduleText = configuration.surveys.map { survey -> String in
            let schedule = survey.schedule
            let weekdays = schedule.weekdays.map { String($0) }.joined(separator: ",")
            let scheduleFields: [String] = [survey.id, String(survey.enabled), schedule.pattern.rawValue, schedule.date ?? "",
                   String(schedule.hour), String(schedule.minute), weekdays,
                   schedule.resolvedAnchor.rawValue, String(schedule.offsetMinutes ?? -1),
                   String(schedule.windowCount ?? -1), String(schedule.windowStartHour ?? -1),
                   String(schedule.windowLengthHours ?? -1)]
            let notificationFields: [String] = [survey.activeStartDate ?? "", survey.activeEndDate ?? "",
                   String(survey.sendNotificationOnOpen), survey.notificationTitle ?? "", survey.notificationBody ?? "",
                   String(survey.promptExpirationMinutes ?? -1)]
            return (scheduleFields + notificationFields).joined(separator: "|")
        }.joined(separator: "||")
        let source = [String(configuration.schemaVersion), configuration.identity.id,
                      String(configuration.notifications.enabled), configuration.schedule.startDate ?? "",
                      configuration.schedule.endDate ?? "", participant.studyID,
                      String(participant.enrollmentDate.timeIntervalSince1970), participant.participationStatus.rawValue,
                      timeZone.identifier, String(policy.rollingHorizonDays),
                      String(policy.maximumPendingRequestsPerStudy), reminderText, surveyScheduleText,
                      String(participant.wakeTimeMinutes ?? -1), String(participant.bedTimeMinutes ?? -1)].joined(separator: "#")
        return fnv1a(source)
    }

    // studyID/seedKey: only actually consulted for `.randomWindow` schedules, to seed each day's
    // random fire times deterministically via `RandomWindowScheduling` — see that type's doc
    // comment for why `seedKey` must match whichever entity's schedule is actually being resolved
    // (a reminder's own schedule seeds by `reminder.id`; a SURVEY's schedule — whether resolved
    // here directly for a survey's own occurrences, or via a linked reminder announcing it —
    // always seeds by `survey.id`, never the reminder's). The other call sites pass a
    // survey/reminder id here too but it's inert for them since their schedule can never actually
    // be `.randomWindow`.
    private func occurrences(for schedule: ReminderScheduleConfiguration, lower: Date, upper: Date,
                             calendar: Calendar, participant: ParticipantState,
                             studyID: String, seedKey: String) -> [Date] {
        if schedule.pattern == .oneTime {
            guard let day = date(schedule.date, calendar: calendar),
                  let value = occurrence(on: day, schedule: schedule, calendar: calendar, participant: participant),
                  value >= lower, value <= upper else { return [] }
            return [value]
        }
        if schedule.pattern == .randomWindow {
            var values = [Date]()
            var day = calendar.startOfDay(for: lower)
            let finalDay = calendar.startOfDay(for: upper)
            while day <= finalDay {
                for value in RandomWindowScheduling.occurrences(on: day, schedule: schedule, calendar: calendar, studyID: studyID, seedKey: seedKey)
                where value >= lower && value <= upper {
                    values.append(value)
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            }
            return values
        }
        var values = [Date]()
        var day = calendar.startOfDay(for: lower)
        let finalDay = calendar.startOfDay(for: upper)
        while day <= finalDay {
            let weekday = calendar.component(.weekday, from: day)
            let matches = schedule.pattern == .daily || schedule.weekdays.contains(weekday)
            if matches, let value = occurrence(on: day, schedule: schedule, calendar: calendar, participant: participant),
               value >= lower, value <= upper { values.append(value) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return values
    }

    /// Resolves a schedule's fire time on a given calendar day. For `.clockTime` (the only style prior
    /// to schemaVersion 6) this is `hour`/`minute` exactly as before. For `.wakeTime`/`.bedTime`, the
    /// day's base time comes from the participant's own sleep schedule (see `SleepScheduleView`) with
    /// `offsetMinutes` added — using `calendar.date(byAdding:)` so an offset that crosses midnight
    /// (e.g. bedtime 00:30 minus 90 minutes) rolls into the correct adjacent day. If the participant
    /// hasn't set a wake/bed time yet, anchor-based schedules simply produce no occurrence for that day.
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
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour; components.minute = minute
        if let exact = calendar.date(from: components) { return exact }
        return calendar.nextDate(after: calendar.startOfDay(for: day), matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }

    private func date(_ value: String?, calendar: Calendar) -> Date? {
        guard let value else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
    private func endOfDay(_ value: String?, calendar: Calendar) -> Date? {
        guard let start = date(value, calendar: calendar), let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return next.addingTimeInterval(-1)
    }
    private func emptyPlan(fingerprint: String) -> NotificationSchedulePlan {
        .init(requests: [], generatedOccurrenceCount: 0, scheduledOccurrenceCount: 0,
              omittedOccurrenceCount: 0, wasTruncated: false, fingerprint: fingerprint)
    }
    private func fnv1a(_ string: String) -> String { String(fnv1aValue(string), radix: 16) }
    private func fnv1aValue(_ string: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }
        return hash
    }
}
