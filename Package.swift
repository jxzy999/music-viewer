// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScoreFilm",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ScoreFilm", targets: ["ScoreFilm"]),
        .library(name: "ScoreCore", targets: ["ScoreCore"])
    ],
    targets: [
        .systemLibrary(name: "CZlib"),
        .target(name: "ScoreCore", dependencies: ["CZlib"]),
        .target(name: "ScoreMedia", dependencies: ["ScoreCore"], resources: [.copy("Resources")]),
        .executableTarget(name: "ScoreFilm", dependencies: ["ScoreCore", "ScoreMedia"], resources: [.copy("Resources")]),
        .testTarget(name: "ScoreCoreTests", dependencies: ["ScoreCore"]),
        .testTarget(name: "ScoreMediaTests", dependencies: ["ScoreCore", "ScoreMedia"])
    ]
)
