// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PhiDependencies",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "Dependencies",
            targets: ["Dependencies"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SnapKit/SnapKit.git", exact: "5.0.1"),
        .package(url: "https://github.com/CocoaLumberjack/CocoaLumberjack.git", exact: "3.9.0"),
        .package(url: "https://github.com/onevcat/Kingfisher.git", exact: "8.5.0"),
        .package(url: "https://github.com/phibrowser/Settings.git", exact: "3.1.4"),
        .package(url: "https://github.com/airbnb/lottie-spm.git", exact: "4.5.2"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", exact: "1.7.3"),
        .package(url: "https://github.com/Cocoanetics/SwiftMail.git", revision: "d16534fbd609feab8c467f4bbd2999c0582278f9"),

    ],
    targets: [
         .target(
            name: "Dependencies",
            dependencies: [
                "MistMailCore",
                .product(name: "SnapKit", package: "SnapKit"),
                .product(name: "CocoaLumberjack", package: "CocoaLumberjack"),
                .product(name: "CocoaLumberjackSwift", package: "CocoaLumberjack"),
                .product(name: "Kingfisher", package: "Kingfisher"),
                .product(name: "Settings", package: "Settings"),
                .product(name: "Lottie", package: "lottie-spm"),
                .product(name: "SwiftMath", package: "SwiftMath"),
            ], path: "Sources/PackageCollection"),
        .target(name: "MistMailCore", dependencies: [.product(name: "SwiftMail", package: "SwiftMail")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MistMailCoreTests", dependencies: ["MistMailCore"], resources: [.copy("Fixtures")],
                    swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
