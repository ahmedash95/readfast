// swift-tools-version: 6.0
// ReadFast for Linux: a GTK 4 frontend over ReadFastCore. Builds on Linux only
// (needs libgtk-4-dev). The macOS app lives in ReadFast.xcodeproj.
import PackageDescription

let package = Package(
    name: "ReadFastLinux",
    dependencies: [.package(path: "../ReadFastCore")],
    targets: [
        .systemLibrary(name: "CGtk", pkgConfig: "gtk4", providers: [.apt(["libgtk-4-dev"])]),
        .executableTarget(
            name: "readfast",
            dependencies: ["CGtk", .product(name: "ReadFastCore", package: "ReadFastCore")],
            // GTK runs everything on its own main loop, not the main actor; we hop
            // threads with g_idle_add (see GLib.swift), so Swift 6 checking only adds noise.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
