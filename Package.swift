// swift-tools-version: 6.0
import PackageDescription
import Foundation
let releaseSettings = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Version.env"), encoding: .utf8)
let minimumMacOS = releaseSettings.split(separator: "\n").first { $0.hasPrefix("CHECKMATE_MINIMUM_MACOS=") }!.split(separator: "=", maxSplits: 1)[1]
let package = Package(
    name: "Checkmate",
    platforms: [.macOS(String(minimumMacOS))],
    products: [.library(name: "CheckmateDomain", targets: ["CheckmateDomain"]), .library(name: "CheckmateApplication", targets: ["CheckmateApplication"]), .executable(name: "CheckmateMCP", targets: ["CheckmateMCP"]), .executable(name: "CheckmateNative", targets: ["CheckmateNative"]), .executable(name: "CheckmateAcceptance", targets: ["CheckmateAcceptance"])],
    dependencies: [.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"), .package(url: "https://github.com/xiaolai/sayso.git", from: "0.4.0")],
    targets: [
        .target(name: "CheckmateMCPKit", dependencies: ["CheckmateCore", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "CheckmateMCP", dependencies: ["CheckmateMCPKit"]),
        .testTarget(name: "CheckmateMCPTests", dependencies: ["CheckmateMCPKit"]),
        .target(name: "CheckmateAssets", dependencies: [], path: "Sources/CheckmateCore", resources: [.copy("Resources")]),
        .target(name: "CheckmateDomain", dependencies: ["CheckmateAssets"]),
        .target(name: "CheckmateSupport", dependencies: ["CheckmateDomain", "CheckmateAssets"]),
        .target(name: "CheckmateRules", dependencies: ["CheckmateDomain", "CheckmateAssets", "CheckmateSupport"]),
        .target(name: "CheckmateEngine", dependencies: ["CheckmateDomain", "CheckmateRules", "CheckmateSupport", "CheckmateAssets"]),
        .target(name: "CheckmateContent", dependencies: ["CheckmateDomain", "CheckmateSupport", "CheckmateAssets", .product(name: "CodexAuth", package: "sayso"), .product(name: "RealtimeConnection", package: "sayso"), .product(name: "SaidGuard", package: "sayso"), .product(name: "PCM16", package: "sayso")]),
        .target(name: "CheckmateApplication", dependencies: ["CheckmateDomain", "CheckmateRules", "CheckmateContent", "CheckmateSupport", "CheckmateAssets"]),
        .target(name: "CheckmateMacPlatform", dependencies: ["CheckmateDomain", "CheckmateRules", "CheckmateEngine", "CheckmateContent", "CheckmateApplication", "CheckmateSupport", "CheckmateAssets", .product(name: "RealtimeConnection", package: "sayso"), .product(name: "SaidGuard", package: "sayso"), .product(name: "PCM16", package: "sayso")]),
        .target(name: "CheckmateCore", dependencies: ["CheckmateDomain", "CheckmateRules", "CheckmateEngine", "CheckmateContent", "CheckmateApplication", "CheckmateMacPlatform", "CheckmateSupport", "CheckmateAssets"], path: "Sources/CheckmateComposition"),
        .executableTarget(name: "CheckmateNative", dependencies: ["CheckmateCore", .product(name: "RealtimeConnection", package: "sayso")]),
        .executableTarget(name: "CheckmateAcceptance", dependencies: ["CheckmateCore", .product(name: "SaidGuard", package: "sayso")], path: "Tools/Acceptance"),
        // Mini-game calibration (WI-016): plays Domain's search and reference players only, on the test host.
        .executableTarget(name: "CheckmateMiniGameCalibration", dependencies: ["CheckmateDomain"], path: "Tools/MiniGameCalibration"),
        // Standard-rule calibration (WI-020): plays the opponent levels with the bundled Stockfish, on the test host.
        .executableTarget(name: "CheckmatePositionGameCalibration", dependencies: ["CheckmateDomain", "CheckmateRules", "CheckmateEngine", "CheckmateApplication"], path: "Tools/PositionGameCalibration"),
        .testTarget(name: "CheckmateCoreTests", dependencies: ["CheckmateTestSupport", "CheckmateCore", "CheckmateDomain", "CheckmateSupport", "CheckmateRules", "CheckmateEngine", "CheckmateContent", "CheckmateApplication", "CheckmateMacPlatform", .product(name: "CodexAuth", package: "sayso"), .product(name: "RealtimeConnection", package: "sayso"), .product(name: "SaidGuard", package: "sayso"), .product(name: "PCM16", package: "sayso")]),
        .testTarget(name: "CheckmateNativeTests", dependencies: ["CheckmateTestSupport", "CheckmateCore", "CheckmateNative", "CheckmateDomain", "CheckmateSupport", "CheckmateRules", "CheckmateEngine", "CheckmateContent", "CheckmateApplication", "CheckmateMacPlatform", .product(name: "SaidGuard", package: "sayso")]),
        .target(name: "CheckmateTestSupport", dependencies: ["CheckmateDomain", "CheckmateRules", "CheckmateEngine"], path: "Tests/CheckmateTestSupport"),
        .testTarget(name: "CheckmateDomainTests", dependencies: ["CheckmateDomain"])
    ],
    swiftLanguageModes: [.v5]
)
// A warning in this project's Swift is a compile error. It fails the compile itself, so no cached build can hide it,
// and no build log has to be read for it to be seen.
for target in package.targets { target.swiftSettings = (target.swiftSettings ?? []) + [.unsafeFlags(["-warnings-as-errors"])] }
