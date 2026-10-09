// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Checkmate",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "CheckmateNative", targets: ["CheckmateNative"]), .executable(name: "CheckmateAcceptance", targets: ["CheckmateAcceptance"])],
    targets: [
        .target(name: "CheckmateCore", resources: [.copy("Resources")]),
        .executableTarget(name: "CheckmateNative", dependencies: ["CheckmateCore"]),
        .executableTarget(name: "CheckmateAcceptance", dependencies: ["CheckmateCore"], path: "Tools/Acceptance"),
        .testTarget(name: "CheckmateCoreTests", dependencies: ["CheckmateCore", "CheckmateNative"])
    ],
    swiftLanguageModes: [.v5]
)
