// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Brow",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "BrowApp", targets: ["BrowApp"]),
    ],
    dependencies: [
        // GroveCore: accounts, credentials, usage and token refresh, shared with Grove.
        .package(url: "https://github.com/efim0v/grove.git", from: "0.2.0"),
    ],
    targets: [
        .target(
            name: "BrowKit",
            dependencies: [.product(name: "GroveCore", package: "grove")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BrowApp",
            dependencies: ["BrowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BrowKitTests",
            dependencies: ["BrowKit", .product(name: "GroveCore", package: "grove")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
