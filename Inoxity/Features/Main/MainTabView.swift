import SwiftUI

struct MainTabView: View {
    let configuration: StudyConfiguration
    @Binding var selection: AppTab
    /// True once the participant has acknowledged `StudyCompletionView` for a study whose
    /// `completion.appAccessRemainsAvailable` is false (see `AppState.isLockedAfterCompletion`).
    /// Restricts `tabs` to a hardcoded `[.settings, .about]`, deliberately NOT filtered through
    /// `configuration.features.visibleTabs` like every other case below — nothing requires a study's
    /// `visibleTabs` to include Settings/About, so reusing the normal filter here could leave a
    /// locked participant with zero reachable tabs and no way to reach support/withdrawal.
    var isLockedAfterCompletion: Bool = false

    /// Home, Surveys, See My Data, Media always lead the tab bar, in this fixed order, when
    /// present — everything else (About, Settings, any future `AppTab` case) follows in whatever
    /// relative order the study's `visibleTabs` config already puts it in. Enforced here so the
    /// bar's order never depends on how a study's JSON config happens to list `visibleTabs`.
    private static let canonicalOrder: [AppTab] = [.home, .surveys, .sleep, .media]

    private var tabs: [AppTab] {
        if isLockedAfterCompletion { return [.settings, .about] }
        let filtered = configuration.features.visibleTabs.filter { tab in
            switch tab {
            case .surveys: configuration.features.surveysEnabled
            case .sleep: configuration.healthKit.enabled && !configuration.healthKit.identifiers.isEmpty
            case .media: configuration.features.mediaUploadsEnabled
            default: true
            }
        }
        let priority = Self.canonicalOrder.filter(filtered.contains)
        let rest = filtered.filter { !Self.canonicalOrder.contains($0) }
        return priority + rest
    }

    var body: some View {
        TabView(selection: $selection) { ForEach(tabs, id: \.self) { tab in destination(tab).tabItem { Label(tab.title, systemImage: tab.symbol) }.tag(tab) } }.tint(InoxityTheme.aqua)
    }
    @ViewBuilder private func destination(_ tab: AppTab) -> some View {
        switch tab {
        case .home: HomeView(configuration: configuration)
        case .surveys: SurveysView(configuration: configuration)
        case .sleep: SeeMyDataView(configuration: configuration)
        case .media: MediaView(configuration: configuration)
        case .about: AboutStudyView(configuration: configuration)
        case .settings: SettingsView(configuration: configuration)
        }
    }
}

/// Participant-facing status screen — deliberately not a navigation dashboard. Surveys, Media,
/// See My Data, About, and Settings all have their own tabs already; Home just answers
/// "I opened the app, am I good?" with a status line, this participant's own progress through the
/// study, and a small daily message. See `HomeStatus` and `StudyProgress` for the logic behind the
/// status line and progress section, kept out of this view so they stay independently testable.
struct HomeView: View {
    let configuration: StudyConfiguration
    @EnvironmentObject private var state: AppState

    private var progress: StudyProgress {
        let startDate = state.participantState.flatMap {
            ParticipantStartDateResolver.resolve(schedule: configuration.schedule, participant: $0)
        }
        return StudyProgress.current(
            startDate: startDate,
            participantDurationDays: configuration.schedule.participantDurationDays
        )
    }

    private var status: HomeStatus {
        HomeStatus.current(
            configuration: configuration,
            healthKitRequestState: state.participantState?.healthKitRequestState,
            surveysAvailable: state.surveySummary.availableCount > 0
        )
    }

    // Home's content is naturally short, which left a large dead gap below it inside the shared
    // `InoxityScreen`'s plain top-anchored ScrollView. Reading the container height via
    // GeometryReader and centering the content within `minHeight: outer.size.height` distributes
    // the leftover space evenly as margin above/below the whole block, rather than concentrating
    // it in one gap — so the page reads as one deliberately composed layout instead of a cluster
    // trailing into empty space — while still scrolling normally if Dynamic Type makes the content
    // taller than the screen.
    var body: some View {
        GeometryReader { outer in
            ZStack {
                InoxityTheme.background.ignoresSafeArea()
                ambientGlow
                ScrollView {
                    VStack(alignment: .leading, spacing: InoxityTheme.Spacing.extraLarge) {
                        header
                        statusSection
                        InoxityCard { progressSection }
                        dailyMessageSection
                    }
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 36)
                    .frame(maxWidth: .infinity, minHeight: outer.size.height, alignment: .center)
                    .foregroundStyle(InoxityTheme.primaryText)
                }
            }
        }
    }

    /// Two very soft, low-opacity color blooms echoing the brandmark's own aqua/pink palette,
    /// tucked behind the header. Purely atmospheric — never competes with text contrast — but
    /// gives the otherwise flat dark background some quiet depth instead of feeling inert.
    private var ambientGlow: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [InoxityTheme.aqua.opacity(0.20), .clear], center: .center, startRadius: 4, endRadius: 220))
                .frame(width: 380, height: 380)
                .offset(x: -140, y: -280)
            Circle()
                .fill(RadialGradient(colors: [InoxityTheme.pink.opacity(0.14), .clear], center: .center, startRadius: 4, endRadius: 200))
                .frame(width: 340, height: 340)
                .offset(x: 150, y: -190)
        }
        .blur(radius: 50)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var header: some View {
        VStack(alignment: .center, spacing: InoxityTheme.Spacing.small) {
            InoxityBrandmark().frame(width: 190)
            Text(configuration.identity.shortName)
                .font(.caption.weight(.semibold))
                .tracking(2)
                .foregroundStyle(InoxityTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, InoxityTheme.Spacing.large)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: InoxityTheme.Spacing.small) {
            Text(status.title)
                .font(.system(.largeTitle, design: .rounded, weight: .light))
            Text(status.message)
                .font(.subheadline)
                .foregroundStyle(InoxityTheme.secondaryText)
        }
    }

    private var progressSection: some View {
        Group {
            if let fraction = progress.fractionComplete, let (day, total) = progress.dayAndTotal {
                HStack(spacing: InoxityTheme.Spacing.medium) {
                    HomeProgressRing(value: fraction, day: day, total: total).frame(width: 76, height: 76)
                    VStack(alignment: .leading, spacing: InoxityTheme.Spacing.small) {
                        Text(progress.title).font(.title2.weight(.medium))
                        Text("Thanks for being part of the study.")
                            .font(.subheadline)
                            .foregroundStyle(InoxityTheme.secondaryText)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: InoxityTheme.Spacing.small) {
                    Text(progress.title).font(.title2.weight(.medium))
                    Text("Thanks for being part of the study.")
                        .font(.subheadline)
                        .foregroundStyle(InoxityTheme.secondaryText)
                }
            }
        }
    }

    private var dailyMessageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TODAY'S THOUGHT")
                .font(.caption.weight(.semibold))
                .tracking(2)
                .foregroundStyle(InoxityTheme.secondaryText)
            Text(DailyMessages.todaysMessage())
                .font(.subheadline)
                .foregroundStyle(InoxityTheme.secondaryText)
        }
        .padding(.bottom, InoxityTheme.Spacing.large)
    }
}

/// Circular "day X of N" progress ring for `StudyProgress.dayOfN` — an aqua-to-pink gradient
/// sweep matching the brandmark's own palette, with the day count as the focal center label.
/// Replaces an earlier flat capsule bar, which read as visually flat next to the rest of the page.
private struct HomeProgressRing: View {
    let value: Double // 0...1, already clamped by StudyProgress
    let day: Int
    let total: Int

    var body: some View {
        ZStack {
            Circle().stroke(InoxityTheme.border, lineWidth: 7)
            Circle()
                .trim(from: 0, to: max(value, 0.03)) // keep a visible sliver even on day 1
                .stroke(
                    AngularGradient(colors: [InoxityTheme.aqua, InoxityTheme.pink], center: .center),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(day)").font(.title3.weight(.semibold))
                Text("of \(total)").font(.caption2).foregroundStyle(InoxityTheme.secondaryText)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Study progress")
        .accessibilityValue("Day \(day) of \(total), \(Int((value * 100).rounded()))%")
    }
}

struct FeaturePlaceholderView: View {
    let title: String, message: String, symbol: String
    var body: some View { InoxityScreen { VStack(alignment: .leading, spacing: 20) { Text(title).font(.system(.largeTitle, design: .rounded, weight: .light)); InoxityCard { Label(message, systemImage: symbol).foregroundStyle(InoxityTheme.aqua) } }.foregroundStyle(InoxityTheme.primaryText) } }
}
