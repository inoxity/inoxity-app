import SwiftUI

struct SeeMyDataView: View {
    @EnvironmentObject private var state: AppState
    let configuration: StudyConfiguration
    @State private var selectedDay = Date()

    var body: some View {
        InoxityScreen {
            VStack(alignment: .leading, spacing: 20) {
                Text("See My Data").font(.system(.largeTitle, design: .rounded, weight: .light))
                Text("Local summaries of readable Apple Health data requested by this study. These summary cards are not uploaded, although configured source samples may sync separately to the verified Study Backend.")
                    .foregroundStyle(InoxityTheme.secondaryText)
                content
                PrimaryButton(title: loading ? "Refreshing…" : "Refresh Apple Health Data", isEnabled: !loading) {
                    Task { await state.refreshHealthSummary() }
                }
                if let date = state.healthSummaryLastRefresh {
                    Text("Last refreshed \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(InoxityTheme.secondaryText)
                }

                Divider()

                Text("Day by Day").font(.title3).fontWeight(.medium)
                DaySelectorHeader(selectedDay: $selectedDay,
                                  // Not bounded to enrollmentDate: this reads live from
                                  // HealthKit (not Supabase), so pre-enrollment history is
                                  // genuinely viewable here — especially now that HealthKit
                                  // backfill (Workstream C) pulls pre-enrollment samples too.
                                  // A fixed 1-year floor just keeps the picker from scrolling
                                  // forever; it isn't tied to any participation state.
                                  earliestDay: Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date(),
                                  latestDay: Date())
                dailyContent
            }.foregroundStyle(InoxityTheme.primaryText)
        }
        .task { if case .idle = state.healthSummaryStatus { await state.refreshHealthSummary() } }
        .task(id: selectedDay) { await state.refreshDailyHealthSummary(day: selectedDay) }
    }

    @ViewBuilder private var content: some View {
        switch state.healthSummaryStatus {
        case .idle:
            emptyCard("Refresh to read available Apple Health data.")
        case .loading:
            InoxityCard { HStack { ProgressView(); Text("Reading Apple Health data…") } }
        case .failed(let message): emptyCard(message)
        case .loaded(let value):
            if value.configuredMetrics.contains("sleepAnalysis"), let summary = value.sleep { sleep(summary) }
            else if value.configuredMetrics.contains("sleepAnalysis") { emptyCard("No sleep data is available yet.") }
            ForEach(sortedKeys(value.quantities), id: \.self) { id in
                quantity(label(id), symbol(id), value.quantities[id]!, includeRange: true)
            }
            ForEach(sortedKeys(value.dailyCumulative), id: \.self) { id in
                daily(label(id), symbol(id), value.dailyCumulative[id]!, includesYesterday: true)
            }
            ForEach(sortedKeys(value.categoryCounts), id: \.self) { id in
                occurrenceCount(label(id), symbol(id), value.categoryCounts[id]!)
            }
            if let summary = value.workouts {
                HealthSummaryCard(title: "Workouts", symbol: "figure.mixed.cardio", rows: [
                    ("Recent workouts", "\(summary.count)"), ("Total duration", duration(summary.totalDuration))
                ])
            }
            if !value.hasData && !value.configuredMetrics.contains("sleepAnalysis") { emptyCard("No readable Apple Health data is available yet.") }
            if !value.unavailableMetrics.isEmpty {
                Text("Some requested Apple Health data could not be read. This can mean there is no available data or access is limited.")
                    .font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
            }
        }
    }

    @ViewBuilder private var dailyContent: some View {
        switch state.dailyHealthSummaryStatus {
        case .idle:
            emptyCard("Choose a day above to see its Apple Health data.")
        case .loading:
            InoxityCard { HStack { ProgressView(); Text("Reading Apple Health data…") } }
        case .failed(let message): emptyCard(message)
        case .loaded(let value):
            if value.configuredMetrics.contains("sleepAnalysis") {
                if let sleepDuration = value.sleepDuration {
                    HealthSummaryCard(title: "Sleep", symbol: "moon.stars", rows: [("Duration", duration(sleepDuration))])
                } else { emptyCard("No sleep data for this day.") }
            }
            ForEach(sortedKeys(value.quantities), id: \.self) { id in
                quantity(label(id), symbol(id), value.quantities[id]!, includeRange: true)
            }
            ForEach(sortedKeys(value.dailyTotals), id: \.self) { id in
                let total = value.dailyTotals[id]!
                HealthSummaryCard(title: label(id), symbol: symbol(id), rows: [("Total", number(total, unit(id)))])
            }
            ForEach(sortedKeys(value.categoryCounts), id: \.self) { id in
                occurrenceCount(label(id), symbol(id), value.categoryCounts[id]!)
            }
            if let summary = value.workouts {
                HealthSummaryCard(title: "Workouts", symbol: "figure.mixed.cardio", rows: [
                    ("Workouts", "\(summary.count)"), ("Total duration", duration(summary.totalDuration))
                ])
            }
            if !value.hasData { emptyCard("No readable Apple Health data for this day.") }
            if !value.unavailableMetrics.isEmpty {
                Text("Some requested Apple Health data could not be read for this day.")
                    .font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
            }
        }
    }

    private var loading: Bool { if case .loading = state.healthSummaryStatus { true } else { false } }
    private func sleep(_ value: SleepSummary) -> some View { HealthSummaryCard(title: "Sleep", symbol: "moon.stars", rows: [
        ("Latest duration", duration(value.latestDuration)), ("Most recent sleep", value.latestDate.formatted(date: .abbreviated, time: .omitted)),
        ("7-day average", value.sevenDayAverage.map(duration) ?? "Not enough data"),
        ("30-day average", duration(value.thirtyDayAverage)), ("Available records", "\(value.recordCount)")]) }
    private func quantity(_ title: String, _ symbol: String, _ value: QuantityMetricSummary, includeRange: Bool = false) -> some View {
        var rows = [("Latest", number(value.latest, value.unit)), ("Recent average", number(value.average, value.unit))]
        if includeRange { rows += [("Recent minimum", number(value.minimum ?? value.latest, value.unit)), ("Recent maximum", number(value.maximum ?? value.latest, value.unit))] }
        return HealthSummaryCard(title: title, symbol: symbol, rows: rows)
    }
    private func daily(_ title: String, _ symbol: String, _ value: DailyMetricSummary, includesYesterday: Bool = false) -> some View {
        var rows = [("Today", number(value.today, value.unit))]
        if includesYesterday { rows.append(("Yesterday", value.yesterday.map { number($0, value.unit) } ?? "No data")) }
        rows.append(("7-day daily average", number(value.sevenDayAverage, value.unit)))
        return HealthSummaryCard(title: title, symbol: symbol, rows: rows)
    }
    private func occurrenceCount(_ title: String, _ symbol: String, _ count: Int) -> some View {
        HealthSummaryCard(title: title, symbol: symbol, rows: [("Recent occurrences", "\(count)")])
    }
    private func emptyCard(_ text: String) -> some View { InoxityCard { Text(text).foregroundStyle(InoxityTheme.secondaryText) } }
    private func duration(_ seconds: TimeInterval) -> String { let minutes = Int((seconds / 60).rounded()); return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min" }
    private func number(_ value: Double, _ unit: String) -> String { "\(value.formatted(.number.precision(.fractionLength(unit == "breaths/min" ? 1 : 0)))) \(unit)" }

    // Reads display metadata generically off HealthKitTypeRegistry instead of one hardcoded
    // title/symbol string per metric — the registry is the single source of truth for both,
    // shared with the wizard/dashboard side.
    private func label(_ identifier: String) -> String { (try? HealthKitTypeRegistry.type(for: identifier).displayLabel) ?? identifier }
    private func symbol(_ identifier: String) -> String { (try? HealthKitTypeRegistry.type(for: identifier).symbol) ?? "questionmark.circle" }
    private func unit(_ identifier: String) -> String { (try? HealthKitTypeRegistry.type(for: identifier))?.canonicalUploadUnit ?? "" }
    private func sortedKeys<Value>(_ dictionary: [String: Value]) -> [String] { dictionary.keys.sorted { label($0) < label($1) } }
}
