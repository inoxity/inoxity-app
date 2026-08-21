import SwiftUI

struct BackendDiagnosticsView: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BACKEND & SYNC").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(InoxityTheme.aqua)
            InoxityCard { VStack(alignment: .leading, spacing: 12) {
                row("Environment", state.backendEnvironmentName)
                row("Control backend", state.backendEnvironmentName == "Not configured" ? "Not configured" : "Configured")
                row("Study route", routingText)
                row("Enrollment", enrollmentText)
                row("Configuration source", state.participantState?.configurationSource?.rawValue.capitalized ?? "Local")
                row("Configuration revision", state.participantState?.enrolledConfigurationRevision.map(String.init) ?? "Not recorded")
                row("Newer revision", state.newerConfigurationRevision.map { "Available (\($0))" } ?? "None detected")
                row("Last sync", state.backendSyncResult?.completedAt.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                row("Pending withdrawals", "\(state.pendingWithdrawalCount)")
                row("Survey events pending", "\(state.surveyEventDiagnostics.pending)")
                row("Survey events acknowledged", "\(state.surveyEventDiagnostics.acknowledged)")
                row("Survey events needing route", "\(state.surveyEventDiagnostics.routingRequired)")
                if let message = state.backendActionMessage { Text(message).font(.footnote).foregroundStyle(InoxityTheme.secondaryText) }
                SecondaryButton(title: "Retry Sync") { Task { await state.retryBackendSync() } }
                Text("Survey events synchronize only with this study’s Study Backend. Apple Health and media uploads are not enabled.").font(.caption).foregroundStyle(InoxityTheme.secondaryText)
            } }
        }
    }
    private var enrollmentText: String {
        switch state.participantState?.enrollmentSyncStatus {
        case .registered: "Registered"
        case .provisional: "Offline enrollment—sync needed"
        case .failedRetryable: "Retry needed"
        case nil: "Local enrollment"
        }
    }
    private var routingText: String {
        switch state.participantState?.backendRoutingStatus {
        case .registered: "Identity verified"
        case .identityVerified, .descriptorCached: "Verified route available"
        case .legacyUnrouted: "Legacy enrollment—route required"
        case .routingRequired: "Routing required"
        case nil: "Not selected"
        }
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(label).foregroundStyle(InoxityTheme.secondaryText); Spacer(); Text(value).multilineTextAlignment(.trailing) }.font(.subheadline)
    }
}
