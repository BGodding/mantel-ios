# Static analysis

Run these before pushing; CI (`.github/workflows/ci.yml`) runs the same set.

| Command | Tool | What it checks |
|---|---|---|
| `swiftformat --lint .` | [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) | Formatting drift. Config: `.swiftformat` (close to defaults; the "wrap every one-line body" rules are off). Apply with `swiftformat .`. |
| `swiftlint lint --strict --config .swiftlint.yml` | [SwiftLint](https://github.com/realm/SwiftLint) 0.65 | Code smells, complexity, force-unwraps, naming. Config: `.swiftlint.yml`. |
| `swiftlint analyze --compiler-log-path build.log` | SwiftLint (analyzer) | Whole-module rules: `unused_declaration`, `unused_import`. Needs an `xcodebuild` log — `xcodebuild … clean build > build.log`. |
| `periphery scan --strict` | [Periphery](https://github.com/peripheryapp/periphery) 2.21 | Dead code — unused types, properties, functions. Config: `.periphery.yml`. |
| `xcodebuild … analyze` | Clang / Swift static analyzer | Nil-deref, leaks, logic bugs. Runs in CI as part of the build. |
| `gitleaks git` / `gitleaks detect --no-git` | [gitleaks](https://github.com/gitleaks/gitleaks) | Committed secrets. The app handles Nextcloud app passwords and `GoogleService-Info.plist` / `Secrets/Secrets.plist` are git-ignored — this enforces they stay that way. |
| Dependabot (`.github/dependabot.yml`) | GitHub | Outdated / vulnerable Swift Package + Actions deps. Tracks the root `Package.swift` + `Package.resolved` pair. |

## Strict concurrency

`project.yml` builds in the Swift 5.10 language mode. To surface data-race smells,
add `SWIFT_STRICT_CONCURRENCY: complete` under the target's `settings.base` and
build — worth doing before a Swift 6 language-mode migration. The one spot that
needs review is `Config.remoteOverrideBaseURL` (`nonisolated(unsafe) static var`,
written once at launch).

## Deliberate rule opt-outs

- **SwiftLint `trailing_comma`** is disabled — SwiftFormat owns trailing-comma
  policy (keeps them on multi-line literals for clean diffs), and the two tools'
  defaults disagree.
- **SwiftLint `cyclomatic_complexity` / `*_length`** thresholds are raised from
  the defaults (complexity 15, file 500, type-body 350, function-body 60). The
  WebDAV status→outcome switches in `UploadCoordinator` / `NextcloudClient` are
  inherently branchy; the raised limits still catch genuine tangle.
- **`force_unwrapping`** is a warning, not an error — `URL(string: "<literal>")!`
  is idiomatic and appears a handful of times against compile-time constants.
- **Periphery `// periphery:ignore`** on `Permission` (full bitmask kept as the
  API Contract §2 reference), `UserInfo` (typed session-check result, parity with
  Android), and `RemoteItem.isDirectory` / `.sizeBytes` (honest PROPFIND model).

## Not yet wired (candidates)

- **GitHub secret scanning + push protection** — turn on in repo settings once
  public; complements gitleaks.
- **CodeQL** (`swift`) — GitHub's semantic analysis for a credential-handling
  networked app.
- **Swift 6 language mode** — currently 5.10; migrate once the strict-concurrency
  pass above is clean.
