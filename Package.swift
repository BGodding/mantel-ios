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
        // Matches `packages.Firebase.minorVersion` in project.yml (~> 11.6).
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", "11.6.0" ..< "11.7.0"),
    ],
    targets: []
)
