// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Brow",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "BrowApp", targets: ["BrowApp"]),
        .executable(name: "grove", targets: ["grove-cli"]),
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
            name: "grove-cli",
            dependencies: ["GroveCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GroveCoreTests",
            dependencies: ["GroveCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GroveAppKitTests",
            dependencies: ["GroveAppKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BrowKitTests",
            dependencies: ["BrowKit", "GroveAppKit", "GroveCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
