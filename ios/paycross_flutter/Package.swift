// swift-tools-version: 5.9
import PackageDescription

// Tools version 5.9, not 6.0: merchants' Xcode must clear this floor to resolve the package.
let package = Package(
    name: "paycross_flutter",
    // A lower minimum fails resolution with an opaque error about the dependency.
    platforms: [.iOS("16.0")],
    products: [.library(name: "paycross-flutter", targets: ["paycross_flutter"])],
    dependencies: [
        // Flutter symlinks this path in at build time: `swift build` alone cannot resolve it, and `import Flutter` compiles only inside a Flutter app build.
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        // upToNextMinor: the SDK is pre-1.0, where breaking changes ship in minor releases.
        .package(url: "https://github.com/paycross/payment-ios-sdk.git", .upToNextMinor(from: "0.8.1")),
    ],
    targets: [
        .target(
            name: "paycross_flutter",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "PayCross", package: "payment-ios-sdk"),
                // Declared directly because the plugin imports PayCrossCore itself.
                .product(name: "PayCrossCore", package: "payment-ios-sdk"),
            ],
            // https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
    ]
)
