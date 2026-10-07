import AVFoundation
import AVKit
import SwiftUI

/// Streams a private Nextcloud video with `AVPlayer`, authenticated with the app-password
/// Basic-auth header — attached only for requests to `Config.host`, like the image loader.
///
/// Playback stops when the view goes away or the app leaves the foreground, so audio
/// never keeps playing in the background.
///
/// Limitation: AVFoundation exposes no redirect hook, so unlike every other request in the
/// app the `Authorization` header can't be guarded against an off-host redirect here. The
/// URL is always built against our own origin, so this needs a hostile server response.
struct VideoPlayerView: View {
    let url: URL
    let credentials: Credentials?

    @State private var player: AVPlayer?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: url) {
            let created = makePlayer()
            player = created
            created.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
            // Give the audio session back so other apps' audio can resume.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active { player?.pause() }
        }
    }

    private func makePlayer() -> AVPlayer {
        // Play with sound even when the ringer switch is silent — it's a video the user opened.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        var options: [String: Any] = [:]
        if let credentials, url.scheme == "https", url.host == Config.host {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": credentials.basicAuthHeader]
        }
        let asset = AVURLAsset(url: url, options: options)
        return AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }
}
