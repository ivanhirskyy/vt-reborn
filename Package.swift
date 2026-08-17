// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VTReborn",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "VTReborn",
            path: "Sources/VTReborn"
        )
    ]
)
