import SwiftUI
import Combine

@MainActor final class StudyCodeViewModel: ObservableObject {
    @Published var code = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    var canContinue: Bool { !StudyCodeNormalizer.normalize(code).isEmpty && !isLoading }
    func submit(using state: AppState) async {
        guard canContinue else { return }; isLoading = true; errorMessage = nil; defer { isLoading = false }
        do { try await state.enroll(with: code) }
        catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? StudyConfigurationError.malformedConfiguration.errorDescription }
    }
}

struct StudyCodeView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = StudyCodeViewModel()
    var body: some View {
        InoxityScreen {
            VStack(alignment: .leading, spacing: 24) {
                InoxityLogo().padding(.bottom, 36)
                Text("JOIN YOUR STUDY").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(InoxityTheme.aqua)
                Text("Enter your study code").font(.system(.largeTitle, design: .rounded, weight: .light)).foregroundStyle(InoxityTheme.primaryText)
                Text("Use the code provided by your study team to configure your Inoxity experience.").foregroundStyle(InoxityTheme.secondaryText).lineSpacing(5)
                StyledTextField(label: "Study code", placeholder: "e.g. STUDY123", text: $model.code)
                    .submitLabel(.continue).onSubmit { Task { await model.submit(using: state) } }
                if let error = model.errorMessage { ErrorMessageView(message: error) }
                if model.isLoading { Label("Finding your study…", systemImage: "hourglass").foregroundStyle(InoxityTheme.secondaryText) }
                PrimaryButton(title: "Continue", isEnabled: model.canContinue) { Task { await model.submit(using: state) } }
                Text("Need help? Contact the research team that invited you.").font(.footnote).foregroundStyle(InoxityTheme.secondaryText).frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}
