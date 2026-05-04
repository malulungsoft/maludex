// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MaludexControlCenter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MaludexControlCenter", targets: ["MaludexControlCenter"])
    ],
    targets: [
        .target(name: "MaludexControlCenterCore"),
        .executableTarget(
            name: "MaludexControlCenter",
            dependencies: ["MaludexControlCenterCore"]
        ),
        .testTarget(
            name: "MaludexControlCenterCoreTests",
            dependencies: ["MaludexControlCenterCore"]
        )
    ]
)
