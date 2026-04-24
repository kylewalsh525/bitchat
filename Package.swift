// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "bitchat",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v16),
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "bitchat",
            targets: ["bitchat"]
        ),
    ],
    dependencies:[
        .package(path: "localPackages/Arti"),
        .package(path: "localPackages/BitFoundation"),
        .package(path: "localPackages/BitLogger"),
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.21.1"),
        .package(url: "https://github.com/cashubtc/cdk-swift.git", exact: "0.14.3")
    ],
    targets: [
        .executableTarget(
            name: "bitchat",
            dependencies: [
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "BitFoundation", package: "BitFoundation"),
                .product(name: "BitLogger", package: "BitLogger"),
                .product(name: "Tor", package: "Arti", condition: .when(platforms: [.macOS])),
                .product(name: "TorStatic", package: "Arti", condition: .when(platforms: [.iOS])),
                .product(name: "CashuDevKit", package: "cdk-swift")
            ],
            path: "bitchat",
            exclude: [
                "Info.plist",
                "Assets.xcassets",
                "_PreviewHelpers/PreviewAssets.xcassets",
                "bitchat.entitlements",
                "bitchat.noappgroups.entitlements",
                "bitchat-macOS.entitlements",
                "bitchat-macOS.noappgroups.entitlements",
                "LaunchScreen.storyboard",
                "ViewModels/Extensions/README.md"
            ],
            resources: [
                .process("Localizable.xcstrings")
            ],
            linkerSettings: [
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .testTarget(
            name: "bitchatTests",
            dependencies: [
                "bitchat",
                .product(name: "BitFoundation", package: "BitFoundation")
            ],
            path: "bitchatTests",
            exclude: [
                "Info.plist",
                "README.md"
            ],
            resources: [
                .process("Localization"),
                .process("Noise")
            ]
        )
    ]
)
