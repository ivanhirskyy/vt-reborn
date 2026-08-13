// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VTPuncher",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "VTPuncher",
            path: "Sources/VTPuncher"
        )
    ]
)
