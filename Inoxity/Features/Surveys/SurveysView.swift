import SwiftUI
import Combine

struct SurveysView: View {
    @EnvironmentObject private var state: AppState
    let configuration: StudyConfiguration

    var body: some View {
        InoxityScreen {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 20) {
                    Text("Surveys").font(.system(.largeTitle, design: .rounded, weight: .light))
                    Text("Configured for \(configuration.identity.shortName)").foregroundStyle(InoxityTheme.secondaryText)
                    if let message = state.surveyErrorMessage { ErrorMessageView(message: message) }
                    if configuration.surveys.filter(\.enabled).isEmpty {
                        InoxityCard { Text("This study does not currently use surveys.").foregroundStyle(InoxityTheme.secondaryText) }
                    } else {
                        section("Available now", statuses: [.available, .opened], empty: "No surveys are available right now.")
                        section("Upcoming", statuses: [.upcoming], empty: nil)
                        section("Completed recently", statuses: [.completed, .done], empty: nil)
                        section("Missed recently", statuses: [.missed], empty: nil)
                    }
                }
                .foregroundStyle(InoxityTheme.primaryText)
                .onChange(of: state.focusedSurveyOccurrenceID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
        .task { state.refreshSurveyRuntime() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            state.refreshSurveyRuntime()
        }
    }

    @ViewBuilder private func section(_ title: String, statuses: Set<SurveyOccurrenceStatus>, empty: String?) -> some View {
        let values = state.surveySummary.occurrences.filter { statuses.contains($0.status) }
        if !values.isEmpty || empty != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(2).foregroundStyle(InoxityTheme.aqua)
                if values.isEmpty, let empty { Text(empty).font(.subheadline).foregroundStyle(InoxityTheme.secondaryText) }
                ForEach(values) { occurrence in
                    SurveyOccurrenceCard(occurrence: occurrence, focused: state.focusedSurveyOccurrenceID == occurrence.id) {
                        state.requestSurveyStart(occurrence.id)
                    }.id(occurrence.id)
                }
            }
        }
    }
}
