// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HagigMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "HagigShell", targets: ["HagigShell"]),
        .executable(name: "HagigScreenshots", targets: ["HagigScreenshots"]),
    ],
    dependencies: [
        // Owner-approved REST client (#46). 1.28.0 is the newest release that
        // Xcode 16.4's SwiftPM can load without the tracing packages.
        .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.28.0"),
        // Already required by AsyncHTTPClient; named so the client can use ByteBuffer,
        // HTTPHeaders and the POSIX event loop group directly. Package.resolved pins it.
        // The pins must satisfy Xcode 16.4 and 27.2 alike: swift-collections stays
        // at 1.6.x (1.7 needs tools 6.2), so swift-async-algorithms stays at 1.1.5,
        // whose 6.2 manifest still accepts it; Xcode 27.2 rewrites a newer pin.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
    ],
    targets: [
        .target(name: "HagigPresentation", dependencies: [
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ]),
        .executableTarget(name: "HagigShell", dependencies: ["HagigPresentation"]),
        .executableTarget(name: "HagigScreenshots", dependencies: ["HagigPresentation"]),
        .testTarget(name: "HagigPresentationTests", dependencies: ["HagigPresentation"]),
    ]
)
