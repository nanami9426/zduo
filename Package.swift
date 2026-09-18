// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ZDuo",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ZDuo", targets: ["ZDuo"])],
    targets: [
        .target(name: "FoldCore"),
        .executableTarget(
            name: "ZDuo", dependencies: ["FoldCore"],
            resources: [.copy("Resources/Fold.metal")],
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("SwiftUI"),
                .linkedFramework("ScreenCaptureKit"), .linkedFramework("IOKit"),
                .linkedFramework("MetalKit"), .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("Carbon")
            ]
        ),
        .testTarget(name: "FoldCoreTests", dependencies: ["FoldCore"])
    ]
)
