import SwiftUI

struct WithdrawalFlowView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var choice: WithdrawalChoice?
    @State private var confirming = false
    @State private var working = false
    @State private var outcome: AppState.WithdrawalOutcome?

    var body: some View {
        NavigationStack {
            InoxityScreen {
                if working {
                    LoadingView(message: "Submitting withdrawal…")
                } else if let outcome {
                    outcomePanel(outcome)
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Withdraw from Study").font(.system(.largeTitle, design: .rounded, weight: .light))
                        Text("Choose what should happen to this study’s local app data.")
                            .foregroundStyle(InoxityTheme.secondaryText)
                        option(.keepExistingData, title: "Withdraw and Keep Existing Data",
                               detail: "Stops future Inoxity queries and reminders while preserving this study’s local survey and media records.")
                        option(.deleteExistingData, title: "Withdraw and Delete Existing Data",
                               detail: "Deletes this study’s local app records and media. Apple Health records are not deleted, and no server deletion is claimed.")
                        SecondaryButton(title: "Cancel") { dismiss() }
                        if let error = state.withdrawalErrorMessage { ErrorMessageView(message: error) }
                    }.foregroundStyle(InoxityTheme.primaryText)
                }
            }
            .confirmationDialog(confirmationTitle, isPresented: $confirming, titleVisibility: .visible) {
                Button(confirmButtonTitle, role: .destructive) {
                    guard let choice else { return }; working = true
                    Task { outcome = await state.withdraw(choice); working = false }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text(confirmationMessage) }
            .interactiveDismissDisabled(working)
        }
    }

    private func option(_ value: WithdrawalChoice, title: String, detail: String) -> some View {
        Button { choice = value; confirming = true } label: {
            InoxityCard { VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); Text(detail).font(.subheadline).foregroundStyle(InoxityTheme.secondaryText) } }
        }.buttonStyle(.plain)
    }
    private var confirmationTitle: String { choice == .deleteExistingData ? "Delete local study data and withdraw?" : "Keep local study data and withdraw?" }
    private var confirmButtonTitle: String { choice == .deleteExistingData ? "Delete Data and Withdraw" : "Keep Data and Withdraw" }
    private var confirmationMessage: String { choice == .deleteExistingData ? "This removes only the active study’s local Inoxity data. It cannot delete Apple Health or server data." : "Future Inoxity collection and reminders stop, while existing local data remains on this device." }

    @ViewBuilder
    private func outcomePanel(_ outcome: AppState.WithdrawalOutcome) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(outcomeTitle(outcome)).font(.system(.largeTitle, design: .rounded, weight: .light))
            Text(outcomeMessage(outcome)).foregroundStyle(InoxityTheme.secondaryText)
            if outcome == .failed, let error = state.withdrawalErrorMessage { ErrorMessageView(message: error) }
            PrimaryButton(title: "Done") { dismiss() }
        }.foregroundStyle(InoxityTheme.primaryText)
    }
    private func outcomeTitle(_ outcome: AppState.WithdrawalOutcome) -> String {
        switch outcome {
        case .confirmedRemotely: "Withdrawal Confirmed"
        case .savedLocallyPendingSync: "Withdrawal Saved"
        case .failed: "Withdrawal Not Completed"
        }
    }
    private func outcomeMessage(_ outcome: AppState.WithdrawalOutcome) -> String {
        switch outcome {
        case .confirmedRemotely: "Your withdrawal has been recorded on the study server."
        case .savedLocallyPendingSync: "Saved on this device. It will be sent to the study server automatically the next time you have a connection."
        case .failed: "Something went wrong and your withdrawal was not saved. Please try again."
        }
    }
}

struct RetainedEnrollmentConflictView: View {
    @EnvironmentObject private var state: AppState
    let conflict: RetainedEnrollmentConflict
    @State private var confirming = false
    var body: some View {
        NavigationStack {
            InoxityScreen { VStack(alignment: .leading, spacing: 20) {
                Text("Retained Study Data").font(.system(.largeTitle, design: .rounded, weight: .light))
                Text("You previously withdrew from \(conflict.configuration.identity.displayName) and chose to keep its local data. It will not be overwritten automatically.")
                    .foregroundStyle(InoxityTheme.secondaryText)
                PrimaryButton(title: "Delete Retained Local Data and Re-enroll") { confirming = true }
                SecondaryButton(title: "Cancel") { state.cancelRetainedReenrollment() }
                Text("Deleting retained data does not delete records from Apple Health or any server.").font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
                if let error = state.withdrawalErrorMessage { ErrorMessageView(message: error) }
            }.foregroundStyle(InoxityTheme.primaryText) }
            .confirmationDialog("Delete retained local data?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Delete and Re-enroll", role: .destructive) { Task { await state.deleteRetainedDataAndReenroll() } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
