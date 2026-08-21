import SwiftUI
import SafariServices

struct InAppSurveyView: UIViewControllerRepresentable {
    let request: SurveyPresentationRequest
    let onPresented: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPresented: onPresented) }
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: request.url)
        DispatchQueue.main.async { context.coordinator.confirm() }
        return controller
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
    final class Coordinator {
        private var didConfirm = false
        private let onPresented: () -> Void
        init(onPresented: @escaping () -> Void) { self.onPresented = onPresented }
        func confirm() { guard !didConfirm else { return }; didConfirm = true; onPresented() }
    }
}
