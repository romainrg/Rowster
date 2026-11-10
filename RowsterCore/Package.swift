// swift-tools-version: 5.10
import PackageDescription

// Logic of Rowster, with no SwiftUI or AppKit.
// Static library: no dynamic framework to embed or sign.
let package = Package(
    name: "RowsterCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RowsterCore", targets: ["RowsterCore"])
    ],
    targets: [
        .target(name: "RowsterCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "RowsterCoreTests", dependencies: ["RowsterCore"])
    ]
)
