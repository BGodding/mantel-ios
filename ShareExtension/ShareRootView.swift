import SwiftUI

/// The Share Extension's own small UI: confirm the incoming items, pick a frame,
/// send. Kept deliberately thin — no gallery, no sign-in — mirroring how the
/// Android share target drops straight into "pick a destination".
struct ShareRootView: View {
    let providers: [NSItemProvider]
    let onFinish: () -> Void
    let onCancel: () -> Void

    @State private var repo = SessionRepository()
    @State private var frames: [Frame] = []
    @State private var loading = true
    @State private var signedIn = true
    @State private var notice: String?
    @State private var sending = false
    @State private var sentMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if !signedIn {
                    ContentUnavailableView(
                        "Sign in first",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("Open Mantel and sign in, then try sharing again.")
                    )
                } else if let sentMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.largeTitle).foregroundStyle(.green)
                        Text(sentMessage).multilineTextAlignment(.center)
                        Text("You can close this — it keeps uploading in the background.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding()
                } else {
                    picker
                }
            }
            .navigationTitle("Send to a frame")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sentMessage == nil ? "Cancel" : "Done") {
                        sentMessage == nil ? onCancel() : onFinish()
                    }
                }
            }
        }
        .task { await bootstrap() }
    }

    private var picker: some View {
        VStack(spacing: 0) {
            Text("\(providers.count) \(providers.count == 1 ? "item" : "items") to send")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

            if let notice {
                Text(notice).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }

            if loading, frames.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if frames.isEmpty {
                ContentUnavailableView(
                    "No frames", systemImage: "photo.on.rectangle.angled",
                    description: Text("No frames are shared with your account yet.")
                )
            } else {
                List(frames) { frame in
                    Button {
                        send(to: frame)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(frame.displayName).font(.headline)
                            Text(frame.remotePath).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(sending)
                }
                .listStyle(.plain)
            }

            if sending { ProgressView().padding() }
        }
    }

    private func bootstrap() async {
        guard repo.currentCredentials() != nil else {
            signedIn = false
            loading = false
            return
        }
        frames = repo.cachedFrames()
        switch await repo.refreshFrames() {
        case let .success(list): frames = list
        case .sessionExpired: signedIn = false
        case .unreachable: notice = frames.isEmpty ? Messages.noConnection : Messages.offlineCached
        case let .serverProblem(code): notice = Messages.serverError(code)
        }
        loading = false
    }

    private func send(to frame: Frame) {
        guard let userId = repo.userId else { signedIn = false; return }
        sending = true
        Task {
            let batchID = UUID().uuidString
            var staged: [StagedFile] = []
            var firstFailure: StagingFailure.Reason?
            for provider in providers {
                let item = SendableItemProvider(provider: provider)
                do {
                    try await staged.append(MediaStaging.stage(item, batchID: batchID))
                } catch {
                    firstFailure = firstFailure ?? (error as? StagingFailure)?.reason
                }
            }
            guard !staged.isEmpty else {
                notice = Messages.stagingFailure(firstFailure)
                sending = false
                return
            }
            repo.lastDestinationID = frame.id
            _ = UploadCoordinator.shared.enqueue(
                destination: frame, userId: userId, staged: staged
            )
            // Don't report "sent" (or let the user dismiss us) until `MKCOL` / chunk tasks
            // exist — an extension torn down before that never starts large files.
            await UploadCoordinator.shared.waitUntilIdle()
            let skipped = providers.count - staged.count
            sentMessage = "Sending \(staged.count) to \(frame.displayName)."
                + (skipped > 0 ? " " + Messages.skippedFiles(skipped) : "")
            sending = false
        }
    }
}
