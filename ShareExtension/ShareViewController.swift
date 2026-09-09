import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Principal class for the Share Extension (Requirements §6 "Entry point A: OS
/// share sheet"). Hosts a SwiftUI destination picker; the actual transfer runs on
/// the same background `URLSession` the app uses, so it continues after this
/// extension is torn down.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let providers = collectProviders()
        let root = ShareRootView(
            providers: providers,
            onFinish: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(
                    withError: NSError(domain: "ShareExtension", code: 0)
                )
            }
        )

        let hosting = UIHostingController(rootView: root)
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    /// Every image/video attachment across all input items, de-duplicated by object.
    private func collectProviders() -> [NSItemProvider] {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let all = items.flatMap { $0.attachments ?? [] }
        return all.filter { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.video.identifier)
        }
    }
}
