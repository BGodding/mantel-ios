# Mantel for iOS

The iOS client for **Mantel**, a private digital-photo-frame system built on
[Nextcloud](https://nextcloud.com/). It is the peer of the Android app at
[BGodding/mantel-android](https://github.com/BGodding/mantel-android) and talks to
the same REST/WebDAV surface. You pick photos/videos (the system share sheet or
`PHPickerViewController`), choose a destination folder, and the app uploads them
to that Nextcloud share over WebDAV. An optional, feature-flagged gallery shows
what's already in a folder.

One idea, same as Android: **the destination list is fetched live from the
Nextcloud share graph** (`GET …/shares?shared_with_me=true`). There is no
per-frame client configuration and no local database — add or remove a share on
the server and the picker reflects it on next refresh.

- SwiftUI, iOS 17, `PRODUCT_BUNDLE_IDENTIFIER` `com.eeinspired.mantel`
- Two targets — the app and a Share Extension — sharing App Group
  `group.com.eeinspired.mantel`

## What it does

| Area | Implementation |
|---|---|
| Auth | Nextcloud username + **app password**, validated against `GET /ocs/v1.php/cloud/user`. Stored in the iOS **Keychain** (`kSecClassGenericPassword`, shared access group, `AfterFirstUnlock`). Re-validated on every launch. |
| Destination discovery | `GET /ocs/v2.php/apps/files_sharing/api/v1/shares?shared_with_me=true` → folders whose `permissions` include the Create bit (4). Cached in the App Group for instant display, server is always source of truth. |
| Upload entry points | **Share Extension** (Photos → share sheet) and in-app **`PHPickerViewController`** — neither needs photo-library permission. |
| Transfer | One **background `URLSession`** (`sharedContainerIdentifier` = App Group). Simple `PUT` below 8 MiB; **WebDAV chunking v2** (`MKCOL` → 10 MiB chunk `PUT`s → `MOVE .file`) at/above. `X-OC-Mtime` set from the asset's capture date (EXIF `DateTimeOriginal` / `AVAsset` creation date — read from the file, no library access). |
| Resilience | Every selection is copied into the App Group container before enqueue, so a deferred/offline/relaunched transfer can always read the bytes. State is persisted per-file in `upload_records.json`; `reconcile()` re-drives anything unfinished at launch and on `handleEventsForBackgroundURLSession`. Exponential backoff on 5xx/network; `401/403/404/507` are terminal and never retried. |
| Error visibility | Per-file outcome in the Uploads screen, copy mapped 1:1 to Requirements §7 (`Messages.swift`). No silent success. |
| Frame gallery (flagged) | `PROPFIND Depth:1` listing, authed preview thumbnails, full-screen viewer, admin `DELETE` with a mandatory confirm dialog. Gated by `gallery_enabled` / `delete_enabled`. |
| Feature flags | **Firebase Remote Config only** (`RemoteFlags.swift`). Ships bundled `false`; read once per launch. |
| Diagnostics | First-party: **MetricKit** (crash + metric payloads) + structured `os_log` (`Telemetry.swift`, subsystem `com.eeinspired.mantel`). Disabled in `DEBUG`. No Crashlytics / Analytics SDK. |
| Screenshot protection | `SecureContainer` on the login screen (blanks on screen-record/mirror and in the app switcher) — the iOS analogue of Android's `FLAG_SECURE`. |

## Where iOS deliberately differs from Android

Requirements §14 explicitly allows this ("iOS is free to differ where the platform
differs").

- **Telemetry:** Android uses Firebase Crashlytics + Analytics. iOS uses
  first-party MetricKit + `os_log`, keeping Firebase to **Remote Config only** —
  closer to the original §8 "nothing beyond Keychain / URLSession / PHPicker"
  posture. Flags still come from Firebase so they match Android's delivery model.
- **Background transfers:** `WorkManager` → background `URLSession` upload tasks.
  Chunk `PUT`s ride the background session; the small `MKCOL` / `MOVE` control
  requests use a foreground `async` session and are re-driven by `reconcile()` if
  the app was suspended between the last chunk and assembly.
- **Share Extension trade-off:** the app and the extension share one background
  session identifier so whichever process runs next receives the completion
  events the other missed. Two simultaneously-live sessions with the same id is
  discouraged by Apple but is low-risk here (the two processes rarely upload at
  once, and each task stays attached to the session that created it).
- **No cross-platform code** — separate codebase, same REST/WebDAV surface (§3).

## Project layout

```
project.yml                 xcodegen spec (the .xcodeproj is generated, git-ignored)
App/                        @main app target (Mantel)
ShareExtension/             share-sheet extension target
Secrets/                    Secrets.example.plist (committed) + Secrets.plist (git-ignored)
Sources/Core/               Config, models, Keychain, NextcloudClient, PROPFIND parser,
                            SessionRepository, RemoteFlags, Telemetry
Sources/Upload/             MediaStaging, background UploadCoordinator, UploadStore
Sources/UI/                 SwiftUI screens (login, destinations, upload status, gallery)
design/AppIcon.svg          editable source for the app icon
Tests/                      unit tests (parsing, bitmask, status classification)
```

## Configure

Two things are kept out of the repo (mirrors the Android client):

1. **`Secrets/Secrets.plist`** — copy `Secrets/Secrets.example.plist` and set your
   own Nextcloud origin and host allowlist:
   ```bash
   cp Secrets/Secrets.example.plist Secrets/Secrets.plist
   ```
   ```
   MANTEL_BASE_URL             https://nextcloud.yourdomain.tld
   MANTEL_ALLOWED_HOST_SUFFIX  yourdomain.tld
   ```
   Both files are bundled; `Secrets.plist` wins when present, otherwise the
   example is used, so a fresh clone still builds and runs against the
   placeholder host. `Config.baseURL` resolves in order: Remote Config
   `server_base_url` (host-checked against `MANTEL_ALLOWED_HOST_SUFFIX`) →
   `Secrets.plist` → `Secrets.example.plist`.

2. **`GoogleService-Info.plist`** in `App/` — from your own Firebase project.
   Without it the app still runs; Remote Config just stays at bundled defaults.
   Keys: `gallery_enabled` (bool), `delete_enabled` (bool), `server_base_url`
   (string).

## Building

Requires Xcode 26+, `xcodegen` (`brew install xcodegen`).

```bash
xcodegen generate
open Mantel.xcodeproj
```

Or from the command line:

```bash
xcodegen generate
xcodebuild -project Mantel.xcodeproj -scheme Mantel \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO build
```

### Before shipping

- **Signing / team:** set `DEVELOPMENT_TEAM` in `project.yml` (currently blank so
  the simulator build needs no signing). The App Group
  `group.com.eeinspired.mantel` and keychain group
  `com.eeinspired.mantel.shared` must exist in the provisioning profile.
- **Firebase / Secrets:** see [Configure](#configure) — both files are
  git-ignored and supplied per environment.
- **Min iOS:** `17.0` (Open Decision C — revisit against the family device
  inventory).
- **Distribution:** TestFlight or ad-hoc (Open Decision D), matching §8.

## App icon

`design/AppIcon.svg` is the editable source (a faithful port of the Android
adaptive icon). Regenerate the 1024 px asset with:

```bash
rsvg-convert -w 1024 -h 1024 -o App/Assets.xcassets/AppIcon.appiconset/AppIcon.png design/AppIcon.svg
```

## Static analysis

`swiftformat --lint .`, `swiftlint --strict`, `periphery scan`, the Clang/Swift
analyzer (in the build), `gitleaks`, and Dependabot. CI runs the lot
(`.github/workflows/ci.yml`). Details, config rationale, and deliberate opt-outs
are in [`docs/static-analysis.md`](docs/static-analysis.md).

## Verified vs. not

The same caveats as the API Contract apply. `PUT` / chunked `PUT` / `MKCOL` /
`MOVE` / discovery / session check follow the shapes validated against a live
Nextcloud host while building the [Android
client](https://github.com/BGodding/mantel-android). `PROPFIND` parsing, the
preview endpoint, and `DELETE` are **not** in that validated set — verify against
your server before enabling the gallery flags for real users.
