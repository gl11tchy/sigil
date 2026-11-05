// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sigil",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sigil", targets: ["SigilApp"]),
        .library(name: "SigilKit", targets: ["SigilKit"]),
        .executable(name: "sigil-mcp", targets: ["SigilMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.18.0")
    ],
    targets: [
        // Lock-free atomics for the crash reporter, which needs ordering a
        // signal handler is allowed to use and Swift cannot give it here.
        .target(name: "SigilAtomics"),
        .target(
            name: "SigilKit",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm"), "SigilAtomics"]
        ),
        .executableTarget(
            name: "SigilApp",
            dependencies: ["SigilKit"]
        ),
        .executableTarget(
            name: "SigilMCP",
            dependencies: ["SigilKit"]
        ),
        .testTarget(
            name: "SigilKitTests",
            dependencies: ["SigilKit"]
        ),
        .testTarget(
            name: "SigilAppTests",
            // Required CI coverage runs in the SwiftUI app host, not the SwiftPM command-line runner.
            dependencies: ["SigilApp", "SigilKit"],
            exclude: ["SidebarVersionNoticeTests.swift", "AboutBuildIdentityHostTests.swift"]
        ),
    ]
)
