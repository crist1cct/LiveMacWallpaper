// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WallpaperStudio",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "WallpaperCore", targets: ["WallpaperCore"])
    ],
    targets: [
        .target(
            name: "WallpaperCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .testTarget(
            name: "WallpaperCoreTests",
            dependencies: ["WallpaperCore"]
        )
    ]
)
