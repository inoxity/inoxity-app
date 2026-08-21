import SwiftUI

struct HealthKitUploadDiagnosticsView: View {
    let configuration: StudyConfiguration
    @EnvironmentObject private var state: AppState
    @State private var diagnostics = HealthKitUploadQueueDiagnostics.empty
    @State private var cursors: [HealthKitSyncCursor] = []
    private let queue = UserDefaultsHealthKitUploadQueue()
    private let cursorStore = UserDefaultsHealthKitSyncCursorStore()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("APPLE HEALTH UPLOAD").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(InoxityTheme.aqua)
            InoxityCard { VStack(alignment: .leading, spacing: 10) {
                row("Eligible", eligible ? "Yes" : "No")
                row("Configured metrics", "\(configuration.healthKit.identifiers.count)")
                row("Pending", "\(diagnostics.pending)"); row("Acknowledged", "\(diagnostics.acknowledged)")
                row("Retry needed", "\(diagnostics.retryNeeded)"); row("Routing required", "\(diagnostics.routingRequired)")
                row("Attention required", "\(diagnostics.attentionRequired)")
                row("Last successful upload", diagnostics.lastSuccessfulUpload?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                row("Initial history", "Up to 30 days after enrollment")
                row("Study Backend", state.participantState?.backendRoutingStatus == .registered ? "Verified" : "Not ready")
                ForEach(cursors, id: \.key.storageKey) { cursor in
                    row((try? HealthKitTypeRegistry.type(for: cursor.key.healthKitIdentifier).displayLabel) ?? cursor.key.healthKitIdentifier,
                        cursor.status == .ready ? "Current" : cursor.status == .awaitingAcknowledgments ? "Awaiting upload" : "Attention needed")
                }
                Text("Phase 3D synchronizes readable HealthKit samples incrementally. Later deletion or correction events reported by Apple Health are not yet synchronized to the Study Backend.")
                    .font(.caption).foregroundStyle(InoxityTheme.secondaryText)
            }}
        }.task { await refresh() }
    }
    private var eligible: Bool {
        configuration.healthKit.enabled && state.participantState?.participationStatus == .enrolled &&
        state.participantState?.enrollmentSyncStatus == .registered && state.participantState?.healthKitRequestState == .requestCompleted
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(label).foregroundStyle(InoxityTheme.secondaryText); Spacer(); Text(value).multilineTextAlignment(.trailing) }.font(.subheadline)
    }
    private func refresh() async {
        guard let studyID = state.participantState?.studyID else { return }
        diagnostics = await queue.diagnostics(studyID: studyID); cursors = await cursorStore.cursors(studyID: studyID)
    }
}
