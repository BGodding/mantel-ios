import SwiftUI

struct DestinationsView: View {
    let repo: SessionRepository
    let pendingCount: Int
    let initialNotice: String?
    let browsingEnabled: Bool
    let onChoosePhotos: () -> Void
    let onCancelPicking: () -> Void
    let onDestinationPicked: (Frame) -> Void
    let onOpenFrame: (Frame) -> Void
    let onSignedOut: (String) -> Void

    @State private var frames: [Frame] = []
    @State private var loading = true
    @State private var loadedOnce = false
    @State private var notice: String?
    @State private var lastUsedID: String?

    private var picking: Bool { pendingCount > 0 }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(picking ? "Send to which frame?" : "Your frames")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Refresh", action: refresh).disabled(loading)
                    }
                    if picking {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Cancel", action: onCancelPicking)
                        }
                    } else {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Sign out") {
                                repo.logOut()
                                onSignedOut("")
                            }
                        }
                    }
                }
        }
        .task {
            lastUsedID = repo.lastDestinationID
            frames = repo.cachedFrames()
            refresh()
        }
        .onAppear { if notice == nil { notice = initialNotice } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if picking {
                Text("\(pendingCount) \(pendingCount == 1 ? "item" : "items") ready — "
                    + "choose where to send \(pendingCount == 1 ? "it" : "them").")
                    .font(.callout)
                    .padding(.horizontal)
            }
            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            listBody

            if !picking {
                Button(action: onChoosePhotos) {
                    Text("Choose photos to upload").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var listBody: some View {
        if loading, frames.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if frames.isEmpty, loadedOnce {
            ContentUnavailableView(
                "No frames yet",
                systemImage: "photo.on.rectangle.angled",
                description: Text("No frames are shared with you yet. Ask your admin to share a "
                    + "frame folder with your account, then tap Refresh.")
            )
        } else {
            List(frames) { frame in
                FrameRow(
                    frame: frame,
                    selectable: picking || browsingEnabled,
                    highlighted: picking && frame.id == lastUsedID,
                    subtitle: subtitle(for: frame)
                ) {
                    if picking { onDestinationPicked(frame) } else if browsingEnabled { onOpenFrame(frame) }
                }
            }
            .listStyle(.plain)
        }
    }

    private func subtitle(for frame: Frame) -> String {
        if picking, frame.id == lastUsedID { return "Last used" }
        if browsingEnabled, !picking { return "Tap to view photos" }
        return frame.remotePath
    }

    private func refresh() {
        loading = true
        Task {
            switch await repo.refreshFrames() {
            case let .success(list):
                frames = list
                notice = nil
            case .sessionExpired:
                onSignedOut(Messages.sessionRevoked)
                return
            case .unreachable:
                notice = Messages.offlineCached
            case let .serverProblem(code):
                notice = Messages.serverError(code)
            }
            loadedOnce = true
            loading = false
        }
    }
}

private struct FrameRow: View {
    let frame: Frame
    let selectable: Bool
    let highlighted: Bool
    let subtitle: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                Text(frame.displayName).font(.headline)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .listRowBackground(highlighted ? Color.accentColor.opacity(0.15) : nil)
    }
}
