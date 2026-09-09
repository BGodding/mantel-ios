import Foundation
import MetricKit
import os

/// First-party diagnostics: `os_log` signposts/events plus a `MetricKit`
/// subscriber for crash + performance payloads.
///
/// Requirements §2/§8 barred third-party telemetry SDKs; §13.3 later added
/// Firebase Crashlytics + Analytics on Android by owner decision. On iOS the
/// platform already provides the equivalent without a dependency:
/// - `MXMetricManager` delivers daily metric payloads and (iOS 14+) crash
///   diagnostics — the Crashlytics equivalent.
/// - Structured `os_log` gives the breadcrumb / event trail, visible in Console
///   and sysdiagnose, and never leaves the device on its own.
///
/// Constraints carried over verbatim: **collection is disabled in DEBUG builds**,
/// and every value logged here is a coarse enum / count / duration — never
/// credentials, tokens, photo bytes, file names, or share paths.
final class Telemetry: NSObject, @unchecked Sendable {
    static let shared = Telemetry()

    private let log = Logger(subsystem: "com.eeinspired.mantel", category: "telemetry")
    private let diagnostics = Logger(subsystem: "com.eeinspired.mantel", category: "diagnostics")

    #if DEBUG
        private let collecting = false
    #else
        private let collecting = true
    #endif

    private var keys: [String: String] = [:]
    private let keysQueue = DispatchQueue(label: "telemetry.keys")

    /// Call once at launch.
    func start() {
        guard collecting else {
            log.debug("telemetry disabled (debug build)")
            return
        }
        MXMetricManager.shared.add(self)
    }

    /// Log a coarse product event. Keys/values must contain no user or file data.
    func event(_ name: String, _ params: [String: Any] = [:]) {
        guard collecting else { return }
        let rendered = params
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        log.info("event \(name, privacy: .public) \(rendered, privacy: .public)")
    }

    /// Non-sensitive breadcrumb — part of the trail attached to a later diagnostic.
    func breadcrumb(_ message: String) {
        guard collecting else { return }
        log.info("crumb \(message, privacy: .public)")
    }

    /// Non-sensitive key/value carried alongside subsequent reports (current screen,
    /// flag state, coarse counts). Never a name/path.
    func setKey(_ key: String, _ value: Any) {
        keysQueue.sync { keys[key] = "\(value)" }
        guard collecting else { return }
        log.info("key \(key, privacy: .public)=\(String(describing: value), privacy: .public)")
    }

    /// Report a handled error without crashing (e.g. a swallowed upload failure,
    /// an orphaned staging collection, server API-shape drift).
    func recordNonFatal(_ error: Error, context: String = "") {
        let snapshot = keysQueue.sync { keys }
        log.error("""
        nonfatal \(context, privacy: .public) \
        \(String(describing: error), privacy: .public) keys=\(snapshot, privacy: .public)
        """)
    }

    enum Events {
        static let loginSuccess = "login_success"
        static let loginFailure = "login_failure"
        static let sessionRevoked = "session_revoked"
        static let framesRefresh = "frames_refresh"
        static let uploadEnqueued = "upload_enqueued"
        static let uploadResult = "upload_result"
    }
}

extension Telemetry: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            diagnostics.info("metric payload \(payload.jsonRepresentation().count, privacy: .public) bytes")
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            diagnostics.error("""
            diagnostic payload crashes=\(payload.crashDiagnostics?.count ?? 0, privacy: .public) \
            hangs=\(payload.hangDiagnostics?.count ?? 0, privacy: .public)
            """)
        }
    }
}
