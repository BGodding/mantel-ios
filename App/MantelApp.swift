import SwiftUI

@main
struct MantelApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Telemetry.shared.start()
        RemoteFlags.configureIfPossible()
        // Instantiate the background session up front so any completions queued by
        // `nsurlsessiond` (including from Share Extension uploads) are replayed.
        Task { @MainActor in UploadCoordinator.shared.attach() }
        return true
    }

    /// The system wakes the app here when background upload tasks finish while it
    /// was suspended/terminated (Requirements §6.4).
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // The app's own session, or the Share Extension's (its uploads finish after it is gone).
        guard Config.allSessionIdentifiers.contains(identifier) else {
            completionHandler()
            return
        }
        Task { @MainActor in
            UploadCoordinator.shared.handleBackgroundEvents(identifier: identifier, completion: completionHandler)
        }
    }
}
