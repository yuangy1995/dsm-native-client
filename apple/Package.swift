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
        .library(name: "DsmCore", targets: ["DsmCore"]),
        .library(name: "DsmNetwork", targets: ["DsmNetwork"]),
        .library(name: "DsmLocalization", targets: ["DsmLocalization"]),
        .executable(name: "LanStash", targets: ["DsmMacExecutable"])
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
        .executableTarget(
            name: "DsmMacExecutable",
            dependencies: ["DsmCore", "DsmNetwork", "DsmLocalization"],
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
            dependencies: ["DsmCore", "DsmNetwork"],
            path: "Apps/DsmMac/FileProviderExtension",
            exclude: [
                "FileProviderExtension.swift",
                "ProviderErrorMapper.swift"
            ],
            sources: [
                "ProviderItem.swift",
                "ProviderRuntime.swift",
                "ProviderEnumerator.swift",
                "ProviderOperationRegistry.swift"
            ]
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
            name: "DsmMacTests",
            dependencies: ["DsmCore", "DsmLocalization", "DsmMacExecutable"],
            path: "Apps/DsmMac/Tests"
        ),
        .testTarget(
            name: "DsmFileProviderRuntimeTests",
            dependencies: ["DsmCore", "DsmFileProviderRuntime"],
            path: "Apps/DsmMac/FileProviderExtensionTests"
        )
    ]
)
