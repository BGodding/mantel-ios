import SwiftUI

/// Top-level screen state machine — the SwiftUI equivalent of the Android
/// `MantelApp` composable.
struct RootView: View {
    @State private var repo = SessionRepository()

    private enum Screen: Equatable {
        case loading
        case login(String?)
        case ready
    }

    @State private var screen: Screen = .loading
    @State private var bootNotice: String?
    @State private var flags = FlagSnapshot()

    @State private var showPicker = false
    @State private var staging = false
    @State private var stagedFiles: [StagedFile] = []
    @State private var stageFailures = 0
    @State private var stageNotice: String?

    @State private var activeBatchID: String?
    @State private var skippedCount = 0
    @State private var galleryFrame: Frame?

    var body: some View {
        Group {
            switch screen {
            case .loading:
                LoadingView()

            case let .login(message):
                LoginView(repo: repo, initialMessage: message) {
                    screen = .ready
                    // Uploads paused by a revoked session resume now.
                    Task { await UploadCoordinator.shared.reconcile() }
                }

            case .ready:
                readyBody
            }
        }
        .task { await boot() }
        .task {
            flags = await RemoteFlags.load()
            Telemetry.shared.setKey("flag_gallery", flags.galleryEnabled)
            Telemetry.shared.setKey("flag_delete", flags.deleteEnabled)
        }
        .onChange(of: screenName, initial: true) {
            Telemetry.shared.setKey("screen", screenName)
            Telemetry.shared.breadcrumb("nav → \(screenName)")
        }
    }

    /// Coarse current-screen label for the crash breadcrumb trail (parity with the
    /// Android client). No user or file data.
    private var screenName: String {
        switch screen {
        case .loading: return "loading"
        case .login: return "login"
        case .ready:
            if galleryFrame != nil { return "gallery" }
            if activeBatchID != nil { return "upload_status" }
            if !stagedFiles.isEmpty { return "pick_destination" }
            return "frames"
        }
    }

    @ViewBuilder
    private var readyBody: some View {
        if let galleryFrame {
            FrameGalleryView(
                frame: galleryFrame,
                repo: repo,
                canDelete: flags.deleteEnabled && galleryFrame.canDelete,
                onBack: { self.galleryFrame = nil },
                onSignedOut: signOut
            )
        } else if let activeBatchID {
            UploadStatusView(batchID: activeBatchID, skippedCount: skippedCount) {
                self.activeBatchID = nil
                skippedCount = 0
                stagedFiles = []
            }
        } else {
            destinations
        }
    }

    private var destinations: some View {
        DestinationsView(
            repo: repo,
            pendingCount: stagedFiles.count,
            initialNotice: stageNotice ?? bootNotice,
            browsingEnabled: flags.galleryEnabled,
            onChoosePhotos: { showPicker = true },
            onCancelPicking: cancelPicking,
            onDestinationPicked: enqueue,
            onOpenFrame: { galleryFrame = $0 },
            onSignedOut: signOut
        )
        .sheet(isPresented: $showPicker) {
            PhotoPicker { providers in
                showPicker = false
                guard !providers.isEmpty else { return }
                stage(providers)
            }
            .ignoresSafeArea()
        }
        .overlay {
            if staging {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Preparing \(stagedFiles.isEmpty ? "your selection" : "…")")
                            .font(.callout)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    // MARK: - Actions

    private func boot() async {
        UploadCoordinator.shared.attach()
        UploadCoordinator.shared.sweepStale()
        switch await repo.bootstrap() {
        case .needsLogin:
            screen = .login(nil)
        case let .revoked(message):
            screen = .login(message)
        case let .ready(notice):
            bootNotice = notice
            screen = .ready
            await UploadCoordinator.shared.reconcile()
        }
    }

    private func stage(_ providers: [NSItemProvider]) {
        staging = true
        stageFailures = 0
        stageNotice = nil
        Task {
            let batchID = UUID().uuidString
            var results: [StagedFile] = []
            var reasons: [String: Int] = [:]
            var firstFailure: StagingFailure.Reason?
            for provider in providers {
                do {
                    let item = SendableItemProvider(provider: provider)
                    try await results.append(MediaStaging.stage(item, batchID: batchID))
                } catch {
                    stageFailures += 1
                    let failure = (error as? StagingFailure)?.reason
                    firstFailure = firstFailure ?? failure
                    reasons[failure?.rawValue ?? "unreadable", default: 0] += 1
                }
            }
            for (reason, count) in reasons {
                Telemetry.shared.event("upload_stage_failed", ["reason": reason, "count": count])
            }
            if results.isEmpty { stageNotice = Messages.stagingFailure(firstFailure) }
            stagedFiles = results
            staging = false
        }
    }

    private func enqueue(_ frame: Frame) {
        guard let userId = repo.userId, !stagedFiles.isEmpty else { return }
        repo.lastDestinationID = frame.id
        skippedCount = stageFailures
        activeBatchID = UploadCoordinator.shared.enqueue(
            destination: frame,
            userId: userId,
            staged: stagedFiles
        )
        stagedFiles = []
    }

    /// Drops the selection and the staged copies made for it.
    private func cancelPicking() {
        for file in stagedFiles {
            try? FileManager.default.removeItem(atPath: file.path)
        }
        stagedFiles = []
        stageFailures = 0
        stageNotice = nil
    }

    private func signOut(_ message: String) {
        stagedFiles = []
        activeBatchID = nil
        galleryFrame = nil
        showPicker = false
        screen = .login(message.isEmpty ? nil : message)
    }
}
