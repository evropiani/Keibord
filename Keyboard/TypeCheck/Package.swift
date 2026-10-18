// swift-tools-version:5.9
// Type-checks and unit-tests the keyboard extension's sources on Linux (there is no Mac: the real iOS
// build only runs on GitHub Actions). `python3 Keyboard/TypeCheck/check.py` copies Keyboard/Sources and
// the Shared files the keyboard needs into Sources/KeyboardCheck/Generated (ObjC-only syntax rewritten)
// and builds/tests them against small UIKit/AudioToolbox stand-ins. Not part of the Xcode project.
import PackageDescription

let package = Package(
    name: "KeyboardTypeCheck",
    dependencies: [.package(path: "../../Core")],
    targets: [
        .target(name: "UIKit", path: "Sources/UIKit"),
        .target(name: "AudioToolbox", path: "Sources/AudioToolbox"),
        .target(name: "KeyboardCheck",
                dependencies: ["UIKit", "AudioToolbox", .product(name: "KeibordCore", package: "Core")],
                path: "Sources/KeyboardCheck"),
        .testTarget(name: "KeyboardCheckTests",
                    dependencies: ["KeyboardCheck", "UIKit", .product(name: "KeibordCore", package: "Core")],
                    path: "Tests/KeyboardCheckTests"),
    ],
    swiftLanguageVersions: [.v5]
)
