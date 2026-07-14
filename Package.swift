// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Manas",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Manas"
        ),
        .testTarget(
            name: "ManasTests",
            dependencies: ["Manas"]
        ),
    ]
)
