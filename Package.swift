// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GetBoredIOSModules",
    platforms: [
        .macOS(.v14),
        .iOS(.v14),
    ],
    products: [
        .library(name: "GetBoredIOSCore", targets: ["GetBoredIOSCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tushru2004/getbored-core", from: "0.1.1"),
    ],
    targets: [
        .target(
            name: "GetBoredIOSCore",
            dependencies: [
                .product(name: "GetBoredCore", package: "getbored-core"),
            ],
            path: "Sources/iOS/Shared"
        ),
        .testTarget(
            name: "IOSContractTests",
            dependencies: [
                "GetBoredIOSCore",
                .product(name: "GetBoredCore", package: "getbored-core"),
            ],
            path: "tests/IOSContractTests"
        ),
    ]
)
