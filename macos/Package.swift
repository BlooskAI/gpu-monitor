// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UtilsGpuMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "GpuMonitor", targets: ["GpuMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "GpuMonitor",
            path: "Sources/GpuMonitor",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Metal")
            ]
        )
    ]
)
