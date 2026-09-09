import SwiftUI

struct FrameGalleryView: View {
    let frame: Frame
    let repo: SessionRepository
    let canDelete: Bool
    let onOpenItem: (RemoteItem) -> Void
    let onBack: () -> Void
    let onSignedOut: (String) -> Void

    @State private var items: [RemoteItem] = []
    @State private var loading = true
    @State private var loadedOnce = false
    @State private var notice: String?
    @State private var pendingDelete: RemoteItem?
    @State private var deleteBusy = false
    @State private var toast: String?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 4)]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(frame.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Back", action: onBack) }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Refresh", action: load).disabled(loading)
                    }
                }
        }
        .task(id: frame.id) { load() }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .alert(
            "Remove this photo?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Remove", role: .destructive, action: confirmDelete).disabled(deleteBusy)
        } message: {
            if let pendingDelete {
                Text("\"\(pendingDelete.name)\" will be removed from \"\(frame.displayName)\" and moved "
                    + "to the server's trash. Anyone viewing that frame will no longer see it.")
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(.red)
                    .padding(.horizontal).padding(.vertical, 8)
            }
            if loadedOnce, !items.isEmpty {
                Text("\(items.count) \(items.count == 1 ? "item" : "items")"
                    + (canDelete ? " · long-press to remove" : ""))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 8)
            }

            if loading, items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty, loadedOnce {
                ContentUnavailableView("No photos yet", systemImage: "photo",
                                       description: Text("This frame has no photos yet."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(items) { item in
                            GalleryTile(item: item, credentials: repo.currentCredentials())
                                .onTapGesture { onOpenItem(item) }
                                .contextMenu {
                                    if canDelete {
                                        Button("Remove from frame", role: .destructive) {
                                            pendingDelete = item
                                        }
                                    }
                                }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func load() {
        loading = true
        Task {
            switch await repo.listFolder(frame) {
            case let .success(list):
                items = list
                notice = nil
            case .sessionExpired:
                onSignedOut(Messages.sessionRevoked)
                return
            case .unreachable:
                notice = Messages.noConnection
            case let .serverProblem(code):
                notice = Messages.serverError(code)
            }
            loadedOnce = true
            loading = false
        }
    }

    private func confirmDelete() {
        guard let target = pendingDelete else { return }
        deleteBusy = true
        Task {
            switch await repo.deleteItem(target) {
            case .success, .alreadyGone:
                items.removeAll { $0.id == target.id }
                showToast("Removed \"\(target.name)\".")
            case .sessionExpired:
                onSignedOut(Messages.sessionRevoked)
                return
            case .forbidden:
                showToast("You don't have permission to remove photos from this frame.")
            case .unreachable:
                showToast(Messages.noConnection)
            case let .serverProblem(code):
                showToast(Messages.serverError(code))
            }
            deleteBusy = false
            pendingDelete = nil
        }
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { toast = nil }
        }
    }
}

private struct GalleryTile: View {
    let item: RemoteItem
    let credentials: Credentials?

    var body: some View {
        ZStack {
            AuthedAsyncImage(url: item.previewURL() ?? item.downloadURL, credentials: credentials)
                .frame(minHeight: 110)
                .aspectRatio(1, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if item.isVideo {
                Image(systemName: "play.fill")
                    .padding(8)
                    .background(.black.opacity(0.55), in: Circle())
                    .foregroundStyle(.white)
            }
        }
        .clipped()
    }
}
