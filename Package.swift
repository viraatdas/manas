// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Manas",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Auto-update. Sparkle owns the whole dance the app must not get
        // wrong: EdDSA-signed feeds, Developer ID validation of the download,
        // and swapping a running bundle out from under itself.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Manas",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                // scripts/make-app.sh drops Sparkle.framework in
                // Contents/Frameworks; the bundled binary looks for it there.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "ManasTests",
            dependencies: ["Manas"]
        ),
    ]
)
