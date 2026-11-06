// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DiagnosticHost",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "MemoryEngine", type: .dynamic, targets: ["MemoryEngine"])
    ],
    targets: [
        .target(name: "MemoryEngine"),
        .testTarget(name: "MemoryEngineTests", dependencies: ["MemoryEngine"])
    ]
)
