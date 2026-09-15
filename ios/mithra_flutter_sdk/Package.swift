// swift-tools-version: 5.9
// The Swift Package Manager path for the mithra_flutter_sdk Flutter plugin.
//
// Flutter looks for a plugin's Swift package at
// ios/<plugin_name>/Package.swift with a target named <plugin_name>, which is
// why this file lives one directory below ios/.
//
// This path resolves the Narya iOS SDK through its hosted Swift package rather
// than vendoring a binary. The CocoaPods path
// (../mithra_flutter_sdk.podspec) downloads and verifies the prebuilt XCFramework
// instead. Both pin the SDK to one exact version: the bridge reproduces SDK
// internals it cannot yet call (see NaryaPushGate), so a floating upper bound
// would let a minor SDK release change behaviour underneath it. Bump the
// version here and in the podspec's `narya_sdk_version` together.

import PackageDescription

let package = Package(
    name: "mithra_flutter_sdk",
    platforms: [
        // Matches the native SDK's own minimum (.iOS(.v15)).
        .iOS(.v15)
    ],
    products: [
        .library(name: "mithra-flutter-sdk", targets: ["mithra_flutter_sdk"])
    ],
    dependencies: [
        .package(url: "https://github.com/MithraAI/mithra-ios-sdk", exact: "1.5.1")
    ],
    targets: [
        .target(
            name: "mithra_flutter_sdk",
            dependencies: [
                .product(name: "MithraAnalytics", package: "mithra-ios-sdk")
            ],
            // Single source of truth: ../mithra_flutter_sdk.podspec points its
            // source_files at this same directory.
            path: "Sources/mithra_flutter_sdk"
        )
    ]
)
