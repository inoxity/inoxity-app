import Foundation

/// A small, static rotation of short messages shown on Home under "Today's thought". Deliberately
/// simple: no network, no persistence, no researcher configuration — just a deterministic pick from
/// a local list, keyed by calendar day so it stays the same for the whole day rather than changing
/// on every render.
enum DailyMessages {
    static let all: [String] = [
        "Small actions repeated consistently can create meaningful data.",
        "The word \u{201C}data\u{201D} comes from the Latin for \u{201C}things given\u{201D} \u{2014} thanks for giving yours.",
        "Studies that follow people over time often reveal patterns a single snapshot can't.",
        "Today's smartphones carry more sensors than most research labs did twenty years ago.",
        "Many everyday health discoveries started with ordinary people agreeing to be observed over time.",
        "Consistency matters more than perfection \u{2014} a missed day or two won't undo your contribution.",
        "Sleep researchers had few reliable ways to measure sleep outside a lab until wearable sensors became common.",
        "A \u{201C}cohort\u{201D} in research just means a group of people followed together over the same period.",
        "Every data point you contribute helps average out the noise in any single measurement.",
        "The first digital pedometer was patented in 1965 \u{2014} long before phones could do the counting for you.",
        "Participant-collected data lets researchers study everyday life, not just lab conditions.",
        "Curiosity is a renewable resource \u{2014} researchers rely on people like you to keep it going.",
        "Even a small, well-run study can shape how future, larger studies get designed.",
        "The idea of \u{201C}informed consent\u{201D} in research only became standard practice in the mid-20th century.",
        "Some of the most useful research findings come from data that looked unremarkable at first.",
        "Your data is one thread in a much larger pattern \u{2014} thanks for weaving it in.",
        "A short daily check-in, done consistently, can be more valuable to researchers than one long survey.",
        "Large-scale mobile health studies using smartphones only became common around 2010 \u{2014} this kind of research is still young.",
        "Daily routines vary more than most people expect; data tends to show the real picture.",
        "Thank you for being part of something that adds up over time.",
        "Wearable technology has made it possible to study things researchers previously had to guess at.",
        "\u{201C}Uneventful\u{201D} days are useful data points too \u{2014} they help establish a baseline.",
        "Anonymized data lets researchers look for patterns without needing to know who anyone is.",
        "It's normal for energy and attention to rise and fall through the day \u{2014} that natural variation is often exactly what researchers are studying.",
        "A study's value often comes less from any single participant and more from the consistency of the group.",
        "Some of today's health guidelines trace back to studies that ran for decades.",
        "You don't need to do anything extra today \u{2014} simply being part of the study counts.",
        "Every completed survey adds a small piece to a much bigger picture.",
        "Researchers often learn as much from what stays the same as from what changes.",
        "Behind every published study are people who just kept showing up \u{2014} like you're doing now."
    ]

    /// Deterministic per calendar day: keyed off `Calendar.ordinality(of:.day, in:.year, for:)` on a
    /// `Date` snapshot, so re-renders within the same day always return the same message. `date`
    /// and `calendar` are parameterized purely so this is easy to unit test with a fixed date.
    static func todaysMessage(date: Date = Date(), calendar: Calendar = .current) -> String {
        guard !all.isEmpty else { return "" }
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        return all[(dayOfYear - 1) % all.count]
    }
}
