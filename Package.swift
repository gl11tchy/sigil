// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GrokBuild",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GrokBuild", targets: ["GrokBuildApp"]),
        .library(name: "GrokBuildKit", targets: ["GrokBuildKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.18.0"),
    ],
    targets: [
        .target(
            name: "GrokBuildKit",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .executableTarget(
            name: "GrokBuildApp",
            dependencies: ["GrokBuildKit"]
        ),
        .testTarget(
            name: "GrokBuildKitTests",
            dependencies: ["GrokBuildKit"]
        ),
    ]
)
