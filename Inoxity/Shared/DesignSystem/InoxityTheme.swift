import SwiftUI

enum InoxityTheme {
    static let background = Color(red: 33/255, green: 17/255, blue: 41/255)
    static let surface = Color(red: 39/255, green: 19/255, blue: 51/255)
    static let elevatedSurface = Color(red: 44/255, green: 22/255, blue: 58/255)
    static let aqua = Color(red: 130/255, green: 216/255, blue: 216/255)
    static let pink = Color(red: 244/255, green: 171/255, blue: 175/255)
    static let primaryText = Color(red: 0.96, green: 0.94, blue: 0.97)
    static let secondaryText = Color(red: 0.70, green: 0.64, blue: 0.73)
    static let border = Color(red: 0.34, green: 0.22, blue: 0.39)
    enum Spacing { static let small: CGFloat = 8, medium: CGFloat = 16, large: CGFloat = 24, extraLarge: CGFloat = 36 }
    static let cornerRadius: CGFloat = 18
}

struct InoxityScreen<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ZStack {
            InoxityTheme.background.ignoresSafeArea()
            ScrollView {
                content.frame(maxWidth: 560).padding(.horizontal, 24).padding(.vertical, 36).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively)
        }
    }
}

struct InoxityLogo: View {
    var body: some View {
        HStack(spacing: 10) {
            Image("InoxityLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            Text("INOXITY").font(.system(.headline, design: .rounded, weight: .medium)).tracking(4)
        }.foregroundStyle(InoxityTheme.primaryText).accessibilityElement(children: .combine).accessibilityLabel("Inoxity")
    }
}

/// The full Inoxity brand lockup (mark + "INOXITY" wordmark baked into one image) used where the
/// logo should read as a standalone hero element rather than a compact header icon — currently
/// Home and the launch splash. `InoxityLogo` above (small icon + separately-set text) remains in
/// use for tighter spots like StudyCode/Onboarding headers. Callers size this via `.frame(width:)`;
/// it has no fixed size of its own since Home and the splash want different scales.
struct InoxityBrandmark: View {
    var body: some View {
        Image("InoxityBrandmark")
            .resizable()
            .scaledToFit()
            .accessibilityLabel("Inoxity")
    }
}
