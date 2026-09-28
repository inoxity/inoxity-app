import SwiftUI

/// Prev/next day navigation for "See My Data" — shows "Today"/"Yesterday"/a formatted date, and
/// disables stepping past `latestDay` (today) or before `earliestDay` (the participant's own
/// enrollment date, since there's no meaningful data before that point for this participant).
struct DaySelectorHeader: View {
    @Binding var selectedDay: Date
    let earliestDay: Date
    let latestDay: Date

    var body: some View {
        HStack {
            Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .disabled(!canStep(-1))
                .accessibilityLabel("Previous day")
            Spacer()
            Text(label).font(.headline).foregroundStyle(InoxityTheme.primaryText)
            Spacer()
            Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .disabled(!canStep(1))
                .accessibilityLabel("Next day")
        }
        .tint(InoxityTheme.aqua)
    }

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(selectedDay) { return "Today" }
        if calendar.isDateInYesterday(selectedDay) { return "Yesterday" }
        return selectedDay.formatted(date: .abbreviated, time: .omitted)
    }

    private func canStep(_ delta: Int) -> Bool { Self.canStep(from: selectedDay, delta: delta, earliestDay: earliestDay, latestDay: latestDay) }

    private func step(_ delta: Int) {
        guard canStep(delta), let next = Calendar.current.date(byAdding: .day, value: delta, to: selectedDay) else { return }
        selectedDay = next
    }

    // Pure and `internal` (not `private`) so it's directly unit-testable without instantiating
    // the view or wiring up a `@Binding`.
    static func canStep(from selectedDay: Date, delta: Int, earliestDay: Date, latestDay: Date) -> Bool {
        let calendar = Calendar.current
        guard let next = calendar.date(byAdding: .day, value: delta, to: selectedDay) else { return false }
        // `next` inherits selectedDay's time-of-day (adding a day preserves the clock time), but
        // earliestDay/latestDay are normalized to startOfDay below — comparing the two directly
        // without also normalizing `next` made the right/"today" arrow wrongly disable itself: in
        // the live view selectedDay starts as `Date()` (real current time, e.g. 3:15pm), so
        // stepping forward to today produced "today 3:15pm", which compares as *greater than*
        // "today 00:00" and got rejected as past latestDay.
        let nextDay = calendar.startOfDay(for: next)
        return nextDay >= calendar.startOfDay(for: earliestDay) && nextDay <= calendar.startOfDay(for: latestDay)
    }
}
