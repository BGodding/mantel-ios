import Foundation

// MARK: - Background session delegate

extension UploadCoordinator {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let descriptor = task.taskDescription
        let status = (task.response as? HTTPURLResponse)?.statusCode
        Task { @MainActor in
            self.handleCompletion(descriptor: descriptor, status: status, transportError: error)
        }
    }

    /// Same policy as the API sessions: never follow a redirect off the original host or
    /// off HTTPS, so the preemptive `Authorization` header can't be replayed elsewhere.
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(RedirectGuard.allows(request, for: task) ? request : nil)
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in
            await self.backgroundEventsDelivered(identifier: identifier)
        }
    }
}

// MARK: - Background wake-ups

extension UploadCoordinator {
    func finishBackgroundEvents(identifier: String) {
        backgroundCompletionHandlers.removeValue(forKey: identifier)?()
    }

    /// The system woke the app for a finished background session: re-drive whatever is
    /// unfinished, wait for it, then tell the system it may suspend the app again.
    func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        backgroundCompletionHandlers[identifier] = completion
        attach(identifier: identifier)
    }

    func backgroundEventsDelivered(identifier: String) async {
        await reconcile()
        // The system only allows ~30s here. Finish early if the tracked work is quick; otherwise
        // hand control back at the deadline (unfinished records are re-driven at next launch).
        Task {
            try? await Task.sleep(for: .seconds(25))
            self.finishBackgroundEvents(identifier: identifier)
        }
        await waitUntilIdle()
        finishBackgroundEvents(identifier: identifier)
    }
}
