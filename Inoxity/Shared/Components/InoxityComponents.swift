import SwiftUI

struct PrimaryButton: View {
    let title: String; var isEnabled = true; let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 52) }
            .buttonStyle(.plain).foregroundStyle(InoxityTheme.background)
            .background(isEnabled ? InoxityTheme.aqua : InoxityTheme.border).clipShape(RoundedRectangle(cornerRadius: 14)).disabled(!isEnabled)
    }
}
struct SecondaryButton: View {
    let title: String; let action: () -> Void
    var body: some View {
        Button(title, action: action).font(.headline).foregroundStyle(InoxityTheme.pink).frame(maxWidth: .infinity, minHeight: 50)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(InoxityTheme.pink))
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
