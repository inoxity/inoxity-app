import SwiftUI

struct SurveyOccurrenceCard: View {
    let occurrence: SurveyOccurrence
    let focused: Bool
    let openAction: () -> Void

    var body: some View {
        InoxityCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(occurrence.name).font(.headline)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(statusText(now: context.date)).font(.caption.weight(.semibold)).foregroundStyle(statusColor)
                    }
                }
                Text(occurrence.summary).font(.subheadline).foregroundStyle(InoxityTheme.secondaryText)
                Text("Scheduled \(occurrence.scheduledFor.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(InoxityTheme.secondaryText)
                Text("Available \(occurrence.opensAt.formatted(date: .omitted, time: .shortened))–\(occurrence.closesAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(InoxityTheme.secondaryText)
                if let completed = occurrence.completedAt { Text("Completed \(completed.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(InoxityTheme.aqua) }
                if occurrence.status == .available || occurrence.status == .opened { PrimaryButton(title: occurrence.status == .opened ? "Return to Survey" : "Open Survey", action: openAction) }
                if let privacy = occurrence.privacyText { Text(privacy).font(.caption).foregroundStyle(InoxityTheme.secondaryText) }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(focused ? InoxityTheme.pink : .clear, lineWidth: 2))
    }

    private func statusText(now: Date) -> String {
        switch occurrence.status {
        case .upcoming: return "Opens in \(Self.countdown(from: now, to: occurrence.opensAt))"
        case .available, .opened: return "\(Self.countdown(from: now, to: occurrence.closesAt)) left"
        case .missed: return "Expired"
        default: return occurrence.status.rawValue.capitalized
        }
    }

    private static func countdown(from now: Date, to target: Date) -> String {
        let seconds = max(0, Int(target.timeIntervalSince(now)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private var statusColor: Color { occurrence.status == .completed ? InoxityTheme.aqua : occurrence.status == .missed ? InoxityTheme.pink : InoxityTheme.primaryText }
}
