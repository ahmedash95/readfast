// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReadFastCore",
    platforms: [.macOS(.v15), .iOS(.v18), .visionOS(.v2)],
    products: [.library(name: "ReadFastCore", targets: ["ReadFastCore"])],
    targets: [
        .target(name: "CReadFast", cSettings: [.unsafeFlags(["-O3"])]),
        .target(name: "ReadFastCore", dependencies: ["CReadFast"]),
        .testTarget(name: "ReadFastCoreTests", dependencies: ["ReadFastCore", "CReadFast"]),
    ]
)
