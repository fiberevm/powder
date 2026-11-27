// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Powder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Powder", targets: ["PowderApp"])
    ],
    dependencies: [
        // secp256k1 signing for Ethereum-style wallets (Hyperliquid orders). Bitcoin Core's libsecp256k1, wrapped.
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.21.1")
    ],
    targets: [
        .executableTarget(
            name: "PowderApp",
            dependencies: [.product(name: "P256K", package: "swift-secp256k1")],
            path: "Sources/PowderApp"
        ),
        .testTarget(
            name: "PowderAppTests",
            dependencies: ["PowderApp"],
            path: "Tests/PowderAppTests"
        )
    ]
)
