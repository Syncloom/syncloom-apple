// swift-tools-version:5.9
import PackageDescription

// Shared Swift package for the macOS and iOS apps: the Rust core through UniFFI, Keychain storage,
// the app model, SwiftUI views and the File Provider implementation.
let package = Package(
    name: "SyncloomKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "SyncloomKit", targets: ["SyncloomKit"])],
    targets: [
        .binaryTarget(name: "SyncloomCoreFFI", path: "Frameworks/SyncloomCore.xcframework"),
        .target(name: "SyncloomKit", dependencies: ["SyncloomCoreFFI"], path: "Sources/SyncloomKit"),
        .testTarget(name: "SyncloomKitTests", dependencies: ["SyncloomKit"], path: "Tests/SyncloomKitTests"),
    ]
)
