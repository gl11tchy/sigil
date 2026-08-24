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
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.18.0"),
    ],
    targets: [
        .target(
            name: "SigilKit",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]
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
            dependencies: ["SigilApp", "SigilKit"]
        ),
    ]
)
