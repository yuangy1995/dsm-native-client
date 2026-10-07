// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DsmShared",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "DsmFileProviderRuntime", targets: ["DsmFileProviderRuntime"]),
        .library(name: "DsmCore", targets: ["DsmCore"]),
        .library(name: "DsmNetwork", targets: ["DsmNetwork"]),
        .library(name: "DsmLocalization", targets: ["DsmLocalization"]),
        .library(name: "DsmVirtualMachineConsoleFeature", targets: ["DsmVirtualMachineConsoleFeature"]),
        .library(name: "DsmFileFeature", targets: ["DsmFileFeature"]),
        .library(name: "DsmPhotosFeature", targets: ["DsmPhotosFeature"]),
        .executable(name: "LanStash", targets: ["DsmMacExecutable"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .target(
            name: "DsmLocalization",
            path: "Packages/DsmLocalization/Sources",
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "DsmCore",
            dependencies: ["DsmLocalization"],
            path: "Packages/DsmCore/Sources"
        ),
        .target(
            name: "DsmNetwork",
            dependencies: ["DsmCore", "DsmLocalization"],
            path: "Packages/DsmNetwork/Sources",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "DsmVirtualMachineConsoleFeature",
            dependencies: ["DsmCore", "DsmLocalization"],
            path: "Packages/DsmVirtualMachineConsoleFeature/Sources"
        ),
        .target(
            name: "DsmFileFeature",
            dependencies: ["DsmCore", "DsmLocalization"],
            path: "Packages/DsmFileFeature/Sources"
        ),
        .target(
            name: "DsmPhotosFeature",
            dependencies: ["DsmCore", "DsmNetwork", "DsmLocalization"],
            path: "Packages/DsmPhotosFeature/Sources"
        ),
        .executableTarget(
            name: "DsmMacExecutable",
            dependencies: [
                "DsmCore", "DsmNetwork", "DsmLocalization", "DsmPhotosFeature", "DsmFileFeature", "DsmVirtualMachineConsoleFeature",
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS]))
            ],
            path: "Apps/DsmMac/Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ImageIO"),
                .linkedFramework("PDFKit"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .target(
            name: "DsmFileProviderRuntime",
            dependencies: ["DsmCore", "DsmNetwork", "DsmLocalization"],
            path: "Packages/DsmFileProviderRuntime/Sources"
        ),
        .testTarget(
            name: "DsmVirtualMachineConsoleFeatureTests",
            dependencies: ["DsmCore", "DsmVirtualMachineConsoleFeature"],
            path: "Packages/DsmVirtualMachineConsoleFeature/Tests"
        ),
        .testTarget(
            name: "DsmCoreTests",
            dependencies: ["DsmCore", "DsmLocalization"],
            path: "Packages/DsmCore/Tests"
        ),
        .testTarget(
            name: "DsmNetworkTests",
            dependencies: ["DsmCore", "DsmNetwork", "DsmLocalization"],
            path: "Packages/DsmNetwork/Tests"
        ),
        .testTarget(
            name: "DsmLocalizationTests",
            dependencies: ["DsmLocalization"],
            path: "Packages/DsmLocalization/Tests"
        ),
        .testTarget(
            name: "DsmPhotosFeatureTests",
            dependencies: ["DsmCore", "DsmPhotosFeature"],
            path: "Packages/DsmPhotosFeature/Tests"
        ),
        .testTarget(
            name: "DsmMacTests",
            dependencies: ["DsmCore", "DsmLocalization", "DsmPhotosFeature", "DsmFileFeature", "DsmMacExecutable"],
            path: "Apps/DsmMac/Tests",
            resources: [.copy("Fixtures/Office")]
        ),
        .testTarget(
            name: "DsmFileProviderRuntimeTests",
            dependencies: ["DsmCore", "DsmFileProviderRuntime"],
            path: "Packages/DsmFileProviderRuntime/Tests"
        )
    ]
)
