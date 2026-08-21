import SwiftUI

/// Branded launch splash shown by `RootView` for a guaranteed minimum duration while the app
/// restores enrollment/config, so the logo reads as an intentional beat (Instagram/Bluesky-style)
/// rather than a flash. Deliberately minimal: just the logo on the themed background, no animation
/// beyond the fade `RootView` applies when dismissing it.
struct SplashView: View {
    var body: some View {
        ZStack {
            InoxityTheme.background.ignoresSafeArea()
            InoxityBrandmark().frame(width: 220)
        }
    }
}
