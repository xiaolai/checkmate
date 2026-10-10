// swift-tools-version: 6.0
import PackageDescription
import Foundation
let releaseSettings = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Version.env"), encoding: .utf8)
let minimumMacOS = releaseSettings.split(separator: "\n").first { $0.hasPrefix("CHECKMATE_MINIMUM_MACOS=") }!.split(separator: "=", maxSplits: 1)[1]
let package = Package(
    name: "Checkmate",
    platforms: [.macOS(String(minimumMacOS))],
    products: [.executable(name: "CheckmateMCP", targets: ["CheckmateMCP"]), .executable(name: "CheckmateNative", targets: ["CheckmateNative"]), .executable(name: "CheckmateAcceptance", targets: ["CheckmateAcceptance"])],
    dependencies: [.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")],
    targets: [
        .target(name: "CheckmateMCPKit", dependencies: ["CheckmateCore", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "CheckmateMCP", dependencies: ["CheckmateMCPKit"]),
        .testTarget(name: "CheckmateMCPTests", dependencies: ["CheckmateMCPKit"]),
        .target(name: "CheckmateCore", resources: [.copy("Resources")]),
        .executableTarget(name: "CheckmateNative", dependencies: ["CheckmateCore"]),
        .executableTarget(name: "CheckmateAcceptance", dependencies: ["CheckmateCore"], path: "Tools/Acceptance"),
        .testTarget(name: "CheckmateCoreTests", dependencies: ["CheckmateCore", "CheckmateNative"])
    ],
    swiftLanguageModes: [.v5]
)
