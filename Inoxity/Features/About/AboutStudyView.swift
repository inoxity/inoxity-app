import SwiftUI

struct AboutStudyView: View {
    @EnvironmentObject private var state: AppState
    let configuration: StudyConfiguration
    @State private var contactSheetPresented = false
    private let contactService = ContactService()

    var body: some View { InoxityScreen { VStack(alignment: .leading, spacing: 20) {
        Text("About the study").font(.system(.largeTitle, design: .rounded, weight: .light))
        Text(configuration.identity.displayName).font(.title3).foregroundStyle(InoxityTheme.aqua)
        Text(configuration.identity.welcomeMessage).foregroundStyle(InoxityTheme.secondaryText)
        Text("DATA HANDLING").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(InoxityTheme.aqua)
        InoxityCard {
            Text("Only configured Apple Health types are read with permission. Local See My Data summaries stay on this device; configured samples may sync to this study’s verified Study Backend. The central Control Backend receives no HealthKit data, and Inoxity does not write to Apple Health.")
                .font(.subheadline).foregroundStyle(InoxityTheme.secondaryText)
        }
        Text("SUPPORT").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(InoxityTheme.pink)
        InoxityCard {
            Text(configuration.support.name).font(.headline)
            Text(configuration.support.email).font(.subheadline).foregroundStyle(InoxityTheme.secondaryText).padding(.top, 5)
            // Both optional: earlier, the dashboard collected these but nothing displayed them.
            if let phone = configuration.support.phone, !phone.trimmingCharacters(in: .whitespaces).isEmpty {
                if let url = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") {
                    Link(phone, destination: url).font(.subheadline).foregroundStyle(InoxityTheme.secondaryText).padding(.top, 2)
                } else {
                    Text(phone).font(.subheadline).foregroundStyle(InoxityTheme.secondaryText).padding(.top, 2)
                }
            }
            if let website = configuration.support.website, !website.isEmpty, let url = URL(string: website) {
                Link(website, destination: url).font(.subheadline).foregroundStyle(InoxityTheme.aqua).padding(.top, 2)
            }
        }
        if contactService.isAvailable {
            SecondaryButton(title: "Contact Research Team") { contactSheetPresented = true }
        }
        Text("FREQUENTLY ASKED QUESTIONS").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(InoxityTheme.pink)
        ForEach(configuration.faqs) { faq in InoxityCard { VStack(alignment: .leading, spacing: 8) { Text(faq.question).font(.headline); Text(faq.answer).font(.subheadline).foregroundStyle(InoxityTheme.secondaryText) } } }
        SecondaryButton(title: "Withdraw from Study") { state.beginWithdrawal() }
        Text("When you withdraw, you can choose to keep the data you’ve already sent to the research team, or delete it from the team’s database and this phone.")
            .font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
    }.foregroundStyle(InoxityTheme.primaryText) }
    .sheet(isPresented: $contactSheetPresented) {
        ContactSheetView(studyCode: configuration.identity.code, supportName: configuration.support.name) {
            contactSheetPresented = false
        }
    } }
}
