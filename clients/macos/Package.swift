// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HagigMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "HagigShell", targets: ["HagigShell"]),
        .executable(name: "HagigScreenshots", targets: ["HagigScreenshots"]),
    ],
    targets: [
        .target(name: "HagigPresentation"),
        .executableTarget(name: "HagigShell", dependencies: ["HagigPresentation"]),
        .executableTarget(name: "HagigScreenshots", dependencies: ["HagigPresentation"]),
        .testTarget(name: "HagigPresentationTests", dependencies: ["HagigPresentation"]),
    ]
)
