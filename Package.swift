// swift-tools-version:6.2
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import PackageDescription

let package = Package(
    name: "Brow",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "BrowApp", targets: ["BrowApp"]),
        // The command-line tool. `grove`, its second name, is a symlink made by packaging.
        .executable(name: "brow", targets: ["brow-cli"]),
    ],
    targets: [
        // Accounts, credentials, usage and token refresh (used by the notch), and
        // git worktrees, cmux, Claude Code sessions and the shared session store
        // (used by Workspaces). It came from the grove repository with its history.
        .target(
            name: "GroveCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The Workspaces panel and its engine state. Never imports BrowKit: what it
        // needs from the app hosting it comes in through protocols and closures.
        .target(
            name: "GroveAppKit",
            dependencies: ["GroveCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The notch, the limits, Settings, and Brow's side of Workspaces.
        .target(
            name: "BrowKit",
            dependencies: ["GroveCore", "GroveAppKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BrowApp",
            dependencies: ["BrowKit", "GroveAppKit", "GroveCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "brow-cli",
            dependencies: ["GroveCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The made-up accounts of the README screenshots, shared by both test bundles that
        // render them so the pictures agree. For tests only: no product links it.
        .target(
            name: "DemoFixture",
            dependencies: ["GroveCore"],
            path: "Tests/DemoFixture",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GroveCoreTests",
            dependencies: ["GroveCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GroveAppKitTests",
            dependencies: ["GroveAppKit", "DemoFixture"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BrowKitTests",
            dependencies: ["BrowKit", "GroveAppKit", "GroveCore", "DemoFixture"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
