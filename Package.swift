// swift-tools-version: 5.10
//
// This manifest is NOT used to build the app — `project.yml` (xcodegen) is the
// authoritative build definition, and it pins Firebase there too. This file
// exists so Dependabot has a manifest + `Package.resolved` pair at the repo root
// to track the Swift Package graph (the generated `Mantel.xcodeproj` is
// git-ignored). Keep the version here in step with `project.yml`.
//
// Refresh the lock file with:  swift package resolve

import PackageDescription

let package = Package(
    name: "MantelDependencies",
    platforms: [.iOS(.v17)],
    dependencies: [
        // Matches `packages.Firebase.majorVersion` in project.yml (from 12.19.0).
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "12.19.0"),
    ],
    targets: []
)
