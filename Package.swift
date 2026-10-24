// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Snowhush",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Snowhush",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Snowhush",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
