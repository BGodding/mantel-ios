import PhotosUI
import SwiftUI

/// `PHPickerViewController` wrapped for SwiftUI (Requirements §6).
///
/// `PHPickerViewController` is used directly (not SwiftUI's `PhotosPicker`)
/// because it hands back an `NSItemProvider` per selection, which
/// `MediaStaging` streams to disk — no whole-file-in-memory load for videos —
/// and it never requires photo-library authorization: the host app only ever
/// sees the specific items the user picked.
struct PhotoPicker: UIViewControllerRepresentable {
    var onComplete: ([NSItemProvider]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 0 // 0 == no limit
        config.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: config)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onComplete: ([NSItemProvider]) -> Void

        init(onComplete: @escaping ([NSItemProvider]) -> Void) {
            self.onComplete = onComplete
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onComplete(results.map(\.itemProvider))
        }
    }
}
