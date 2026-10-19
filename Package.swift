// swift-tools-version: 6.0
import PackageDescription
import Foundation

let coreOnly = ProcessInfo.processInfo.environment["INFRA_CORE_ONLY"] == "1"
let bridgeOnly = ProcessInfo.processInfo.environment["INFRA_BRIDGE_ONLY"] == "1"

let package = Package(
    name: "InfraTerminal",
    platforms: [.macOS(.v14)],
    products: (bridgeOnly ? [] : [.library(name: "InfraCore", targets: ["InfraCore"])]) + (coreOnly || bridgeOnly ? [] : [
        .executable(name: "InfraTerminal", targets: ["InfraTerminalApp"])
    ]),
    dependencies: coreOnly ? [] : [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", revision: "42bacd1339f323a693ddbca779295f4f77e5a697")
    ],
    targets: (bridgeOnly ? [] : [
        .target(name: "InfraCore"),
        .testTarget(name: "InfraCoreTests", dependencies: ["InfraCore"])
    ]) + (coreOnly ? [] : [
        .target(name: "TerminalBridge", dependencies: [.product(name: "GhosttyTerminal", package: "libghostty-spm")]),
        .testTarget(name: "TerminalBridgeTests", dependencies: ["TerminalBridge"])
    ]) + (coreOnly || bridgeOnly ? [] : [
        .target(name: "InfraTerminalUI", dependencies: ["InfraCore", "TerminalBridge"]),
        .executableTarget(name: "InfraTerminalApp", dependencies: ["InfraTerminalUI", "TerminalBridge"]),
        .testTarget(name: "InfraTerminalUITests", dependencies: ["InfraTerminalUI"])
    ]),
    swiftLanguageModes: [.v5]
)
