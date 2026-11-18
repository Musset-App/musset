// swift-tools-version:5.9
// MussetPage: Musset's reading engine for macOS and iOS. Pages composed by musset-typeset (Rust, on the Typst
// library), marks drawn over them. Build the engine first: scripts/build-typeset.sh.
import PackageDescription

let package = Package(
    name: "MussetPage",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MussetPage", targets: ["MussetPage"]),
    ],
    targets: [
        .binaryTarget(name: "MussetTypeset", path: "MussetTypeset.xcframework"),
        .target(name: "MussetPage", dependencies: ["MussetTypeset"]),
        .testTarget(name: "MussetPageTests", dependencies: ["MussetPage"]),
    ]
)
