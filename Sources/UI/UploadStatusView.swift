import SwiftUI

struct UploadStatusView: View {
    let batchID: String
    let onDone: () -> Void

    @State private var store = UploadCoordinator.shared.store

    private var records: [UploadRecord] { store.records(batchID: batchID) }
    private var total: Int { records.count }
    private var sent: Int { records.filter { $0.state == .succeeded }.count }
    private var failed: Int { records.filter { $0.state == .failed }.count }
    private var allFinished: Bool { total > 0 && records.allSatisfy(\.isFinished) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(summary)
                    .font(.headline)
                    .padding(.horizontal)

                List(records) { record in
                    UploadRow(record: record)
                }
                .listStyle(.plain)

                Button {
                    if allFinished { store.clearFinished() }
                    onDone()
                } label: {
                    Text(allFinished ? "Done" : "Keep uploading in the background")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .navigationTitle("Uploads")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            // Reflect completions that landed while this view was gone.
            await UploadCoordinator.shared.reconcile()
        }
    }

    private var summary: String {
        if total == 0 { return "Preparing…" }
        if allFinished, failed == 0 { return "All \(total) sent." }
        if allFinished { return "\(sent) of \(total) sent · \(failed) didn't finish." }
        return "\(sent) of \(total) sent…"
    }
}

private struct UploadRow: View {
    let record: UploadRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.displayName).font(.subheadline).bold()
            Text("\(statusText) · \(record.destinationLabel)")
                .font(.footnote)
                .foregroundStyle(isError ? Color.red : Color.secondary)
        }
    }

    private var isError: Bool { record.state == .failed }

    private var statusText: String {
        switch record.state {
        case .waiting: "Waiting"
        case .uploading: "Uploading…"
        case .assembling: "Finishing…"
        case .succeeded: "Sent"
        case .failed: Messages.uploadError(record.errorKind)
        }
    }
}
