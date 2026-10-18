// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Daraoke",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Daraoke", targets: ["Daraoke"]),
        .library(name: "CDGCore", targets: ["CDGCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20")
    ],
    targets: [
        .target(name: "CDGCore"),
        .target(name: "KaraokeAudio"),
        .target(name: "KaraokeImport", dependencies: [
            .product(name: "ZIPFoundation", package: "ZIPFoundation")
        ]),
        .executableTarget(name: "Daraoke", dependencies: ["CDGCore", "KaraokeImport", "KaraokeAudio"]),
        .testTarget(name: "CDGCoreTests", dependencies: ["CDGCore"]),
        .testTarget(name: "KaraokeAudioTests", dependencies: ["KaraokeAudio"]),
        .testTarget(name: "KaraokeImportTests", dependencies: ["KaraokeImport",
            .product(name: "ZIPFoundation", package: "ZIPFoundation")
        ])
    ],
    swiftLanguageModes: [.v6]
)
