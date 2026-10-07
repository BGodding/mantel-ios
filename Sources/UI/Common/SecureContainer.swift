import SwiftUI
import UIKit

/// iOS analogue of Android's `FLAG_SECURE` for screens that show credentials
/// (Requirements §8 "FLAG_SECURE on the login screen").
///
/// iOS has no App Store-safe API to block a single still screenshot. What is
/// achievable first-party, and what this does:
///  - blanks the content whenever a screen recording or AirPlay mirror is active
///    (`UIWindowScene.screen.isCaptured` across connected scenes);
///  - blanks the content whenever the app leaves the foreground, so it does not
///    appear in the app-switcher snapshot.
///
/// It intentionally does **not** use the private/fragile "host content inside a
/// secure `UITextField` layer" trick — that breaks layout and is not contractual
/// API. The realistic threat for a shared family device (someone recording the
/// screen, or thumbing through the app switcher) is covered.
struct SecureContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @Environment(\.scenePhase) private var scenePhase
    /// `nil` until the first check, which counts as hidden — never a frame of exposed content.
    @State private var captured: Bool?

    var body: some View {
        content()
            .overlay {
                if shouldHide {
                    ZStack {
                        Rectangle().fill(.background)
                        Image(systemName: "eye.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                    .ignoresSafeArea()
                }
            }
            .onAppear { captured = SecureContainer.anyScreenCaptured() }
            .onReceive(NotificationCenter.default.publisher(
                for: UIScreen.capturedDidChangeNotification
            )) { _ in
                captured = SecureContainer.anyScreenCaptured()
            }
    }

    private var shouldHide: Bool {
        captured ?? true || scenePhase != .active
    }

    /// `true` if any connected window scene's screen is being captured (recording,
    /// mirroring, AirPlay). Uses `UIWindowScene.screen`, not the deprecated
    /// `UIScreen.main`.
    private static func anyScreenCaptured() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.screen.isCaptured }
    }
}
