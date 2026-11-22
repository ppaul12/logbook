// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Logbook",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LogbookCore", path: "LogbookCore"),
        .testTarget(name: "LogbookTests", dependencies: ["LogbookCore"], path: "Tests")
    ]
)
