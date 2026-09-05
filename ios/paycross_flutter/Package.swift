// swift-tools-version: 5.9
import PackageDescription

// The plugin's Swift Package Manager face. Flutter reads this when the app is
// built with SPM enabled; the podspec beside it describes the same sources to
// CocoaPods, and both must keep working -- Flutter's SPM support is opt-in, so
// merchants arrive by either route.
//
// 5.9, not the SDK's 6.0: the tools version is the floor a merchant's Xcode has
// to clear to resolve this package at all, and nothing here needs 6.0 to be
// expressed. The wrapped SDK still builds under its own Swift 6 language mode.
let package = Package(
    name: "paycross_flutter",
    // 16.0, matching the wrapped SDK. Declared lower, the mismatch surfaces
    // during resolution as an opaque error about the dependency rather than as
    // a legible minimum-version message.
    platforms: [.iOS("16.0")],
    products: [.library(name: "paycross-flutter", targets: ["paycross_flutter"])],
    dependencies: [
        // A relative path with no package at the other end of it, until Flutter
        // symlinks this package next to its generated FlutterFramework inside
        // ios/Flutter/ephemeral/Packages/.packages/. That is the only place
        // this package is ever resolved, which is why every Flutter plugin's
        // Package.swift spells the dependency exactly this way, and why
        // `swift build` run here on its own cannot resolve it.
        //
        // Without it the plugin's `import Flutter` only compiles because a
        // CocoaPods integration happened to be left in the host project. A
        // merchant on a project with no Podfile would not be that lucky.
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        // upToNextMinor, not upToNextMajor: the SDK is pre-1.0, where SemVer
        // puts breaking changes in the minor. The podspec pins the same
        // release exactly, so the two package managers cannot resolve a
        // merchant onto different native code.
        .package(url: "https://github.com/paycross/payment-ios-sdk.git", .upToNextMinor(from: "0.5.0")),
    ],
    targets: [
        .target(
            name: "paycross_flutter",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "PayCross", package: "payment-ios-sdk"),
                // Declared even though PayCross depends on it: the plugin
                // imports PayCrossCore directly for PaymentResult, Recovery
                // and PendingReason, and a module it imports is a dependency
                // it should name rather than inherit.
                .product(name: "PayCrossCore", package: "payment-ios-sdk"),
            ],
            // https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
    ]
)
