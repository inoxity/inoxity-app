import UIKit

@MainActor
protocol SystemSettingsOpening {
    func openNotificationSettings()
    /// Opens the Health app to its home screen (`x-apple-health://`) — the only sanctioned deep link
    /// Apple exposes. There is no supported URL scheme that jumps straight to Health > Sharing > Apps
    /// > Inoxity, so the participant still has to navigate there manually.
    func openHealthApp()
}

@MainActor
struct SystemSettingsOpener: SystemSettingsOpening {
    func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    func openHealthApp() {
        guard let url = URL(string: "x-apple-health://") else { return }
        UIApplication.shared.open(url)
    }
}
