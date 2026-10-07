import SwiftUI

struct FrameGalleryView: View {
    let frame: Frame
    let repo: SessionRepository
    let canDelete: Bool
    let onBack: () -> Void
    let onSignedOut: (String) -> Void

    @State private var items: [RemoteItem] = []
    @State private var loading = true
    @State private var loadedOnce = false
    @State private var notice: String?
    @State private var pendingDelete: RemoteItem?
    @State private var deleteBusy = false
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    /// Presented over this view (not swapped in for it), so returning from the viewer keeps
    /// the scroll position, filter, sort and loaded items — no reload.
    @State private var viewerItem: RemoteItem?
    @SceneStorage("gallery.filter") private var filter: MediaFilter = .all
    @SceneStorage("gallery.sort") private var sort: GallerySort = .recentlyAdded

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 4)]

    private var visibleItems: [RemoteItem] { items.filteredAndSorted(filter, sort) }

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
        .fullScreenCover(item: $viewerItem) { item in
            FrameImageView(
                frame: frame,
                item: item,
                repo: repo,
                canDelete: canDelete,
                onDeleted: {
                    items.removeAll { $0.id == item.id }
                    viewerItem = nil
                },
                onBack: { viewerItem = nil },
                onSignedOut: onSignedOut
            )
        }
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
                filterBar
            }

            if loading, items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleItems.isEmpty, loadedOnce {
                ContentUnavailableView(
                    items.isEmpty ? "No photos yet" : "Nothing here",
                    systemImage: "photo",
                    description: Text(items.isEmpty
                        ? "This frame has no photos yet."
                        : "Nothing matches this filter.")
                )
            } else {
                grid
            }
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Show", selection: $filter) {
                ForEach(MediaFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                let count = visibleItems.count
                Text("\(count) \(count == 1 ? "item" : "items")")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(GallerySort.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Label("Sort: \(sort.label)", systemImage: "arrow.up.arrow.down")
                        .font(.callout)
                }
            }

            if canDelete {
                Text("Long-press a photo to remove it")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var grid: some View {
        // Read once per render, not once per tile (a signed-out read hits the Keychain).
        let credentials = repo.currentCredentials()
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(visibleItems) { item in
                    GalleryTile(item: item, credentials: credentials)
                        .onTapGesture { viewerItem = item }
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
        toastTask?.cancel()
        withAnimation { toast = message }
        // Replaces any earlier timer, so an older toast can't clear a newer one.
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
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
