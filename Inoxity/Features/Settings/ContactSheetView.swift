import SwiftUI

/// "Contact Research Team" sheet, presented from AboutStudyView's SUPPORT
/// card (not Settings — moved there per an earlier design change). Sends via
/// ContactService, which relays to the dashboard's /api/contact route and
/// writes nothing to inoxity_backend — see ContactService.swift for the
/// full data-flow explanation.
struct ContactSheetView: View {
    let studyCode: String
    let supportName: String
    let dismiss: () -> Void

    @State private var message = ""
    @State private var replyToEmail = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var sentSuccessfully = false
    @FocusState private var focusedField: Field?
    private let service = ContactService()

    private enum Field { case message, email }

    private var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        // NavigationStack only so the keyboard's "Done" toolbar reliably appears inside this sheet;
        // its navigation bar stays hidden, so the screen looks the same as before.
        NavigationStack {
            content
                .toolbar(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focusedField = nil }.fontWeight(.semibold)
                    }
                }
        }
    }

    private var content: some View {
        InoxityScreen {
            VStack(alignment: .leading, spacing: 20) {
                Text("Contact \(supportName)").font(.system(.largeTitle, design: .rounded, weight: .light))
                    .dismissesKeyboardOnTap($focusedField)

                if sentSuccessfully {
                    SuccessMessageView(message: "Your message was sent to the research team.")
                    SecondaryButton(title: "Done", action: dismiss)
                } else {
                    Text("Send a message directly to the research team running this study. This isn't stored by Inoxity — it's only relayed to them by email.")
                        .font(.footnote).foregroundStyle(InoxityTheme.secondaryText)
                        .dismissesKeyboardOnTap($focusedField)

                    messageField
                    emailField

                    if let errorMessage { ErrorMessageView(message: errorMessage) }

                    PrimaryButton(title: isSending ? "Sending…" : "Send", isEnabled: canSend, action: send)
                    SecondaryButton(title: "Cancel", action: dismiss)
                }
            }
            .foregroundStyle(InoxityTheme.primaryText)
            // Covers the gaps between the form's elements. A background (not an .onTapGesture on
            // the whole VStack) so tapping into a text field doesn't also immediately unfocus it.
            .background(Color.clear.dismissesKeyboardOnTap($focusedField))
        }
    }

    @ViewBuilder private var messageField: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("MESSAGE").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(InoxityTheme.secondaryText)
                .dismissesKeyboardOnTap($focusedField)
            TextEditor(text: $message)
                .focused($focusedField, equals: .message)
                .frame(minHeight: 140)
                .padding(10)
                .scrollContentBackground(.hidden)
                .background(InoxityTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(InoxityTheme.border))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder private var emailField: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("YOUR EMAIL (OPTIONAL, SO THEY CAN REPLY)")
                .font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(InoxityTheme.secondaryText)
                .dismissesKeyboardOnTap($focusedField)
            TextField("you@example.com", text: $replyToEmail)
                .focused($focusedField, equals: .email)
                .submitLabel(.done).onSubmit { focusedField = nil }
                .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, 16).frame(minHeight: 54).background(InoxityTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(InoxityTheme.border))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func send() {
        focusedField = nil
        isSending = true
        errorMessage = nil
        let trimmedEmail = replyToEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await service.send(.init(
                    studyCode: studyCode,
                    message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                    replyToEmail: trimmedEmail.isEmpty ? nil : trimmedEmail))
                sentSuccessfully = true
            } catch {
                errorMessage = (error as? ContactServiceError)?.errorDescription ?? "Something went wrong. Please try again."
            }
            isSending = false
        }
    }
}

private extension View {
    /// Tapping this view (not a text field) hides the keyboard.
    func dismissesKeyboardOnTap<Value: Hashable>(_ focus: FocusState<Value?>.Binding) -> some View {
        contentShape(Rectangle()).onTapGesture { focus.wrappedValue = nil }
    }
}
