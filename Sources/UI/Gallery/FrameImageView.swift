import SwiftUI

/// Full-screen viewer for one gallery item: an image, or a streaming video.
struct FrameImageView: View {
    let frame: Frame
    let item: RemoteItem
    let repo: SessionRepository
    let canDelete: Bool
    let onDeleted: () -> Void
    let onBack: () -> Void
    let onSignedOut: (String) -> Void

    @State private var confirming = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if item.isVideo {
                    VideoPlayerView(url: item.downloadURL, credentials: repo.currentCredentials())
                } else {
                    AuthedAsyncImage(
                        url: item.downloadURL,
                        credentials: repo.currentCredentials(),
                        contentMode: .fit
                    ) {
                        PreviewPendingTile()
                    }
                }

                if let error {
                    VStack {
                        Spacer()
                        Text(error)
                            .foregroundStyle(.white)
                            .padding(16)
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Back", action: onBack) }
                if canDelete {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Delete", role: .destructive) { confirming = true }
                    }
                }
            }
        }
        .alert("Remove this photo?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) { confirming = false }
            Button("Remove", role: .destructive, action: confirmDelete).disabled(busy)
        } message: {
            Text("\"\(item.name)\" will be removed from \"\(frame.displayName)\" and moved to the "
                + "server's trash. Anyone viewing that frame will no longer see it.")
        }
    }

    private func confirmDelete() {
        busy = true
        error = nil
        Task {
            switch await repo.deleteItem(item) {
            case .success, .alreadyGone:
                onDeleted()
                return
            case .sessionExpired:
                onSignedOut(Messages.sessionRevoked)
                return
            case .forbidden:
                error = "You don't have permission to remove photos from this frame."
            case .unreachable:
                error = Messages.noConnection
            case let .serverProblem(code):
                error = Messages.serverError(code)
            }
            busy = false
            confirming = false
        }
    }
}
