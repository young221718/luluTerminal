// swift-tools-version: 6.0
import PackageDescription
import Foundation

let coreOnly = ProcessInfo.processInfo.environment["INFRA_CORE_ONLY"] == "1"
let bridgeOnly = ProcessInfo.processInfo.environment["INFRA_BRIDGE_ONLY"] == "1"
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let localGhostty = ProcessInfo.processInfo.environment["LULU_GHOSTTY_PACKAGE"] ?? packageRoot.appendingPathComponent(".cache/ghostty14/libghostty-spm").path
if !coreOnly && !FileManager.default.fileExists(atPath: localGhostty + "/BinaryTarget/GhosttyKit.xcframework/Info.plist") {
    fatalError("Ghostty 1.4 is not prepared. Run bash scripts/prepare-ghostty14.sh .cache/ghostty14 /path/to/zig-0.17.0; see docs/GHOSTTY_BUILD.md.")
}
let ghosttyDependency: Package.Dependency = .package(name: "libghostty-spm", path: localGhostty)

let package = Package(
    name: "InfraTerminal",
    platforms: [.macOS(.v14)],
    products: (bridgeOnly ? [] : [.library(name: "InfraCore", targets: ["InfraCore"])]) + (coreOnly || bridgeOnly ? [] : [
        .executable(name: "InfraTerminal", targets: ["InfraTerminalApp"])
    ]),
    dependencies: coreOnly ? [] : [
        ghosttyDependency
    ],
    targets: (bridgeOnly ? [] : [
        .target(name: "InfraSSHPTY"),
        .target(name: "InfraCore", dependencies: ["InfraSSHPTY"]),
        .testTarget(name: "InfraCoreTests", dependencies: ["InfraCore"])
    ]) + (coreOnly ? [] : [
        .target(name: "TerminalBridge", dependencies: [.product(name: "GhosttyTerminal", package: "libghostty-spm")]),
        .testTarget(name: "TerminalBridgeTests", dependencies: ["TerminalBridge"])
    ]) + (coreOnly || bridgeOnly ? [] : [
        .target(name: "InfraTerminalUI", dependencies: ["InfraCore", "TerminalBridge"]),
        .executableTarget(name: "InfraTerminalApp", dependencies: ["InfraTerminalUI", "TerminalBridge", "InfraCore"]),
        .testTarget(name: "InfraTerminalUITests", dependencies: ["InfraTerminalUI"])
    ]),
    swiftLanguageModes: [.v5]
)
