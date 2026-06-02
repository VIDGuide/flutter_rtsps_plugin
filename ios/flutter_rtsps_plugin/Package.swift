// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "flutter_rtsps_plugin",
    platforms: [
        .iOS("14.0")
    ],
    products: [
        // The plugin name contains "_", so the library name uses "-" instead.
        .library(name: "flutter-rtsps-plugin", targets: ["flutter_rtsps_plugin"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        // Test-only dependency. Dependencies of non-root packages are not
        // resolved for consumers, so this does not affect apps that depend on
        // this plugin (e.g. the PandaWatch app or the example app).
        .package(url: "https://github.com/typelift/SwiftCheck.git", from: "0.12.0")
    ],
    targets: [
        .target(
            name: "flutter_rtsps_plugin",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                // The plugin ships a privacy manifest describing its (empty)
                // privacy impact. Required for App Store submission.
                .process("PrivacyInfo.xcprivacy")
            ]
        ),
        .testTarget(
            name: "flutter_rtsps_pluginTests",
            dependencies: [
                "flutter_rtsps_plugin",
                "SwiftCheck",
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
