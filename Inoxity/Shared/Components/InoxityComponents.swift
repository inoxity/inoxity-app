import SwiftUI

struct PrimaryButton: View {
    let title: String; var isEnabled = true; let action: () -> Void
    var body: some View {
        // Size, background and contentShape live inside the label: a Button is only as tappable as
        // its label, so styling applied outside it leaves everything but the text dead to taps.
        Button(action: action) {
            Text(title).font(.headline).foregroundStyle(InoxityTheme.background).frame(maxWidth: .infinity, minHeight: 52)
                .background(isEnabled ? InoxityTheme.aqua : InoxityTheme.border).clipShape(RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain).disabled(!isEnabled)
    }
}
struct SecondaryButton: View {
    let title: String; let action: () -> Void
    var body: some View {
        // See PrimaryButton — the frame and contentShape must be inside the label to be tappable.
        Button(action: action) {
            Text(title).font(.headline).foregroundStyle(InoxityTheme.pink).frame(maxWidth: .infinity, minHeight: 50)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(InoxityTheme.pink))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}
struct StyledTextField: View {
    let label: String, placeholder: String; @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label.uppercased()).font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(InoxityTheme.secondaryText)
            TextField(placeholder, text: $text).textInputAutocapitalization(.characters).autocorrectionDisabled()
                .padding(.horizontal, 16).frame(minHeight: 54).background(InoxityTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(InoxityTheme.border)).clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}
struct ErrorMessageView: View {
    let message: String
    var body: some View { Label(message, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(InoxityTheme.pink).frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel("Error: \(message)") }
}
struct SuccessMessageView: View {
    let message: String
    var body: some View { Label(message, systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(InoxityTheme.aqua).frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel("Success: \(message)") }
}
struct LoadingView: View {
    let message: String
    var body: some View { ZStack { InoxityTheme.background.ignoresSafeArea(); VStack(spacing: 18) { ProgressView().tint(InoxityTheme.aqua).controlSize(.large); Text(message).foregroundStyle(InoxityTheme.secondaryText) } } }
}
struct InoxityCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View { content.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(InoxityTheme.surface).overlay(RoundedRectangle(cornerRadius: 18).stroke(InoxityTheme.border)).clipShape(RoundedRectangle(cornerRadius: 18)) }
}
struct OnboardingProgress: View {
    let current: Int, total: Int
    var body: some View { HStack(spacing: 7) { ForEach(0..<total, id: \.self) { i in Capsule().fill(i <= current ? InoxityTheme.aqua : InoxityTheme.border).frame(height: 4) } }.accessibilityLabel("Step \(current + 1) of \(total)") }
}
