import Foundation

@MainActor
final class HealthSummaryService: HealthSummaryProviding {
    private let query: any HealthDataQuerying
    private let now: @Sendable () -> Date

    init(query: any HealthDataQuerying, now: @escaping @Sendable () -> Date = { Date() }) {
        self.query = query; self.now = now
    }

    func snapshot(configuration: StudyConfiguration, participant: ParticipantState) async throws -> HealthSummarySnapshot {
        guard participant.participationStatus == .enrolled else { throw HealthSummaryError.withdrawn }
        guard configuration.healthKit.enabled, !configuration.healthKit.identifiers.isEmpty else { throw HealthSummaryError.noConfiguredMetrics }
        guard query.isAvailable else { throw HealthSummaryError.unavailable }
        let end = now()
        var calendar = Calendar(identifier: .gregorian)
        // Rolling window is scoped to the participant's own current local "day", consistent
        // with the rest of the app's participant-local timezone model.
        calendar.timeZone = .current
        let start = calendar.date(byAdding: .day, value: -30, to: end) ?? end.addingTimeInterval(-30 * 86_400)
        let interval = DateInterval(start: start, end: end)
        let configured = Self.configuredIdentifiers(configuration)
        var result = HealthSummarySnapshot(generatedAt: end, configuredMetrics: configured)

        for identifier in configured {
            guard let metadata = try? HealthKitTypeRegistry.type(for: identifier) else { continue }
            do {
                switch (metadata.sampleKind, identifier) {
                case (.category, "sleepAnalysis"):
                    result.sleep = Self.sleepSummary(samples: try await query.sleepSamples(in: interval), interval: interval, now: end, calendar: calendar)
                case (.category, _):
                    let count = try await query.categorySampleCount(for: identifier, in: interval)
                    if count > 0 { result.categoryCounts[identifier] = count }
                case (.workout, _):
                    let values = try await query.workouts(in: interval)
                    if !values.isEmpty { result.workouts = .init(count: values.count, totalDuration: values.reduce(0) { $0 + $1.duration }) }
                case (.quantity, _):
                    try await Self.populateQuantity(identifier: identifier, metadata: metadata, query: query, interval: interval,
                        now: end, calendar: calendar, quantities: &result.quantities, dailyCumulative: &result.dailyCumulative)
                case (.correlation, _):
                    continue // not yet surfaced in local summaries — see HealthKitTypeRegistry's doc comment
                }
            } catch { result.unavailableMetrics.insert(identifier) }
        }
        return result
    }

    /// Same underlying HealthKit reads as `snapshot(configuration:participant:)` — just scoped to
    /// exactly one calendar day instead of a rolling 30-day window, for "See My Data"'s
    /// day-by-day navigation. Deliberately reuses `Self.quantitySummary`/`clipped`/`subtract`/
    /// `merge` rather than duplicating this logic.
    func dailySnapshot(configuration: StudyConfiguration, participant: ParticipantState, day: Date, timeZone: TimeZone? = nil) async throws -> DailyHealthSnapshot {
        guard participant.participationStatus == .enrolled else { throw HealthSummaryError.withdrawn }
        guard configuration.healthKit.enabled, !configuration.healthKit.identifiers.isEmpty else { throw HealthSummaryError.noConfiguredMetrics }
        guard query.isAvailable else { throw HealthSummaryError.unavailable }
        var calendar = Calendar(identifier: .gregorian)
        // Defaults to the participant's current local zone (like NotificationScheduleBuilder/
        // SurveyOccurrenceBuilder) — injectable so tests can pin a specific zone rather than
        // depend on whatever machine the test suite happens to run on.
        calendar.timeZone = timeZone ?? .current
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? day
        let interval = DateInterval(start: start, end: end)
        let configured = Self.configuredIdentifiers(configuration)
        var result = DailyHealthSnapshot(day: start, configuredMetrics: configured)

        for identifier in configured {
            guard let metadata = try? HealthKitTypeRegistry.type(for: identifier) else { continue }
            do {
                switch (metadata.sampleKind, identifier) {
                case (.category, "sleepAnalysis"):
                    // Sleep uses its OWN padded query interval, not the plain single-day `interval`
                    // every other metric above uses — see `sleepQueryInterval`'s doc comment for why.
                    let sleepInterval = Self.sleepQueryInterval(for: day, calendar: calendar)
                    result.sleepDuration = Self.dailySleepDuration(samples: try await query.sleepSamples(in: sleepInterval), day: day, calendar: calendar)
                case (.category, _):
                    let count = try await query.categorySampleCount(for: identifier, in: interval)
                    if count > 0 { result.categoryCounts[identifier] = count }
                case (.workout, _):
                    let values = try await query.workouts(in: interval)
                    if !values.isEmpty { result.workouts = .init(count: values.count, totalDuration: values.reduce(0) { $0 + $1.duration }) }
                case (.quantity, _):
                    switch metadata.aggregationStrategy {
                    case .cumulativeDaily:
                        if let total = Self.total(try await query.dailyCumulativeValues(for: identifier, in: interval, calendar: calendar)) {
                            result.dailyTotals[identifier] = total
                        }
                    case .latestValue:
                        if let summary = Self.quantitySummary(try await query.quantitySamples(for: identifier, in: interval), unit: metadata.canonicalUploadUnit ?? "", includeRange: true) {
                            result.quantities[identifier] = summary
                        }
                    case .sampleCount, .none: break
                    }
                case (.correlation, _):
                    continue
                }
            } catch { result.unavailableMetrics.insert(identifier) }
        }
        return result
    }

    private static func configuredIdentifiers(_ configuration: StudyConfiguration) -> Set<String> {
        Set(configuration.healthKit.identifiers).intersection(HealthKitTypeRegistry.supportedIdentifiers)
    }

    /// Shared by both `snapshot`/`dailySnapshot`'s quantity branch would duplicate this dispatch
    /// twice otherwise — kept as one static helper since Swift can't easily share an `inout`
    /// mutation across two differently-shaped call sites (rolling summary vs. single-day total)
    /// without it; `dailySnapshot` above inlines its own (simpler, single-value) version instead.
    private static func populateQuantity(
        identifier: String, metadata: HealthKitTypeMetadata, query: any HealthDataQuerying, interval: DateInterval,
        now: Date, calendar: Calendar, quantities: inout [String: QuantityMetricSummary], dailyCumulative: inout [String: DailyMetricSummary]
    ) async throws {
        let unit = metadata.canonicalUploadUnit ?? ""
        switch metadata.aggregationStrategy {
        case .cumulativeDaily:
            if let summary = Self.dailySummary(try await query.dailyCumulativeValues(for: identifier, in: interval, calendar: calendar), now: now, calendar: calendar, unit: unit) {
                dailyCumulative[identifier] = summary
            }
        case .latestValue:
            if let summary = Self.quantitySummary(try await query.quantitySamples(for: identifier, in: interval), unit: unit, includeRange: true) {
                quantities[identifier] = summary
            }
        case .sampleCount, .none:
            break
        }
    }

    /// A gap this wide between two asleep fragments is treated as the boundary between two
    /// separate sleep sessions — e.g. last night's sleep vs. a nap the next afternoon — rather
    /// than just a stir in the middle of one continuous night. Ordinary mid-night awakenings
    /// (checking the time, rolling over) are minutes to under an hour; a genuinely new episode is
    /// typically many hours of wakefulness away, so 4h sits safely between the two without
    /// needing per-study configuration.
    private static let sessionGapTolerance: TimeInterval = 4 * 3_600

    /// Groups the asleep-minus-awake blocks within `interval` into sessions (see
    /// `sessionGapTolerance`), then attributes EACH session's total duration to
    /// `calendar.startOfDay(for: session.end)` in full — the wake day, matching how Apple's own
    /// Health app attributes a whole night's sleep to the day the person woke up, not the day
    /// they fell asleep. Bucketing by session, not by each individually-merged asleep fragment,
    /// matters because a single night's sleep is routinely split into several disjoint asleep
    /// fragments by brief awake periods; a prior version of this function bucketed each fragment
    /// by its own end day, which correctly kept one *uninterrupted* overnight block together
    /// across midnight, but still misattributed a night's *first* fragment — the one before an
    /// early, pre-midnight stir — to the previous calendar day, undercounting the true wake day
    /// and overcounting the day before by the same amount. Grouping into sessions first keeps a
    /// fragmented-but-continuous night under one wake day regardless of where its awake blips
    /// fall, while a genuinely separate nap hours later still lands in its own session/day.
    /// Sessions are grouped from the asleep blocks alone (not raw awake/in-bed samples) — two
    /// asleep fragments separated by a brief awake period already sit within `sessionGapTolerance`
    /// of each other without needing the awake sample as an extra input, and pulling in awake/
    /// in-bed activity from elsewhere in the window risked chaining unrelated daytime samples
    /// (a nap, a period of resting-in-bed) into the same session as an unrelated night's sleep.
    /// Callers computing a single day's duration must pass an `interval` padded well before that
    /// day's own start (see `sleepQueryInterval`) so a session starting the evening before is
    /// actually present in `samples` to group in the first place — this function only
    /// groups/buckets what it's given, it doesn't itself widen the window.
    private static func sleepDayBuckets(samples: [HealthSleepSample], interval: DateInterval, calendar: Calendar) -> [Date: TimeInterval] {
        let asleep = samples.filter { $0.state == .asleep }.compactMap { clipped($0.startDate, $0.endDate, to: interval) }
        let awake = samples.filter { $0.state == .awake }.compactMap { clipped($0.startDate, $0.endDate, to: interval) }
        let sleepWithoutAwake = asleep.flatMap { subtract($0, awake: awake) }
        let asleepBlocks = merge(sleepWithoutAwake)
        let sessions = merge(asleepBlocks, gapTolerance: sessionGapTolerance)
        var records: [Date: TimeInterval] = [:]
        for block in asleepBlocks where block.end > block.start {
            guard let session = sessions.first(where: { $0.start <= block.start && block.end <= $0.end }) else { continue }
            let day = calendar.startOfDay(for: session.end)
            records[day, default: 0] += block.end.timeIntervalSince(block.start)
        }
        return records
    }

    /// How far back a single day's sleep query looks before that day's own start, so an overnight
    /// session that began the evening before is actually fetched from HealthKit rather than
    /// silently clipped away. A flat 24h lookback needs no per-study configuration — sleep
    /// sessions essentially never start more than a day before wake time.
    private static func sleepQueryInterval(for day: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? day
        let paddedStart = calendar.date(byAdding: .hour, value: -24, to: start) ?? start
        return DateInterval(start: paddedStart, end: end)
    }

    /// `samples` must already have been queried over `sleepQueryInterval(for: day, calendar:)` —
    /// see that function's and `sleepDayBuckets`' doc comments for why. Returns nil if no sleep
    /// was recorded for `day`.
    private static func dailySleepDuration(samples: [HealthSleepSample], day: Date, calendar: Calendar) -> TimeInterval? {
        let interval = sleepQueryInterval(for: day, calendar: calendar)
        return sleepDayBuckets(samples: samples, interval: interval, calendar: calendar)[calendar.startOfDay(for: day)]
    }

    private static func total(_ values: [HealthDailyValue]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0) { $0 + $1.value }
    }

    static func sleepSummary(samples: [HealthSleepSample], interval: DateInterval, now: Date, calendar: Calendar) -> SleepSummary? {
        let records = sleepDayBuckets(samples: samples, interval: interval, calendar: calendar)
        guard let latest = records.max(by: { $0.key < $1.key }) else { return nil }
        let thirty = records.values.reduce(0, +) / Double(records.count)
        let sevenStart = calendar.date(byAdding: .day, value: -7, to: now) ?? interval.start
        let recent = records.filter { $0.key >= calendar.startOfDay(for: sevenStart) }.map(\.value)
        return .init(latestDuration: latest.value, latestDate: latest.key,
                     sevenDayAverage: recent.isEmpty ? nil : recent.reduce(0, +) / Double(recent.count),
                     thirtyDayAverage: thirty, recordCount: records.count)
    }

    private static func quantitySummary(_ values: [HealthQuantityPoint], unit: String, includeRange: Bool = false) -> QuantityMetricSummary? {
        guard let latest = values.max(by: { $0.date < $1.date }), !values.isEmpty else { return nil }
        let numbers = values.map(\.value)
        return .init(latest: latest.value, average: numbers.reduce(0, +) / Double(numbers.count),
                     minimum: includeRange ? numbers.min() : nil, maximum: includeRange ? numbers.max() : nil, unit: unit)
    }

    private static func dailySummary(_ values: [HealthDailyValue], now: Date, calendar: Calendar, unit: String) -> DailyMetricSummary? {
        guard !values.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let sevenStart = calendar.date(byAdding: .day, value: -6, to: today)!
        let byDay = Dictionary(values.map { (calendar.startOfDay(for: $0.day), $0.value) }, uniquingKeysWith: +)
        let recent = byDay.filter { $0.key >= sevenStart && $0.key <= today }.values
        guard !recent.isEmpty else { return nil }
        return .init(today: byDay[today] ?? 0, yesterday: byDay[yesterday],
                     sevenDayAverage: recent.reduce(0, +) / 7.0, unit: unit)
    }

    private static func clipped(_ start: Date, _ end: Date, to interval: DateInterval) -> DateInterval? {
        let lower = max(start, interval.start), upper = min(end, interval.end)
        return lower < upper ? DateInterval(start: lower, end: upper) : nil
    }
    private static func subtract(_ value: DateInterval, awake: [DateInterval]) -> [DateInterval] {
        awake.reduce([value]) { pieces, cut in pieces.flatMap { piece in
            guard cut.start < piece.end, cut.end > piece.start else { return [piece] }
            var result: [DateInterval] = []
            if piece.start < cut.start { result.append(.init(start: piece.start, end: min(cut.start, piece.end))) }
            if cut.end < piece.end { result.append(.init(start: max(cut.end, piece.start), end: piece.end)) }
            return result
        } }
    }
    /// `gapTolerance` lets adjacent-but-not-touching intervals merge too — used by `sleepDayBuckets`
    /// to group a night's sleep-related activity into sessions (see `sessionGapTolerance`). Every
    /// other caller relies on the default of 0, i.e. true overlap/adjacency only.
    private static func merge(_ values: [DateInterval], gapTolerance: TimeInterval = 0) -> [DateInterval] {
        let sorted = values.sorted { $0.start < $1.start }; guard var current = sorted.first else { return [] }
        var result: [DateInterval] = []
        for next in sorted.dropFirst() {
            if next.start <= current.end + gapTolerance { current = .init(start: current.start, end: max(current.end, next.end)) }
            else { result.append(current); current = next }
        }
        result.append(current); return result
    }
}
