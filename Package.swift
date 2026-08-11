// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CoderBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CoderBarKit"),
        .executableTarget(
            name: "coder-bar",
            dependencies: ["CoderBarKit"]
        ),
        .executableTarget(
            name: "coder-bar-hook",
            dependencies: ["CoderBarKit"]
        ),
        .executableTarget(
            name: "coder-bar-ctl",
            dependencies: ["CoderBarKit"]
        ),
    ]
)
