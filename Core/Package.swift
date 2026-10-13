// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KeibordCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "KeibordCore", targets: ["KeibordCore"]),
    ],
    targets: [
        .target(name: "KeibordCore", path: "Sources/KeibordCore"),
        .testTarget(
            name: "KeibordCoreTests",
            dependencies: ["KeibordCore"],
            path: "Tests/KeibordCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
