// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LogDuck",
    // async/await back-deploys to these versions via the Swift 5.5 concurrency
    // runtime, so there is no reason to require anything newer.
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6),
    ],
    products: [
        .library(name: "LogDuck", targets: ["LogDuck"])
    ],
    targets: [
        .target(name: "LogDuck"),
        .testTarget(name: "LogDuckTests", dependencies: ["LogDuck"]),
    ]
)
