// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "0718-memory-stress",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/shinyaoguri/metaphor.git", from: "0.5.3")
    ],
    targets: [
        .executableTarget(
            name: "Sketch0718MemoryStress",
            dependencies: [
                .product(name: "metaphor", package: "metaphor")
            ],
            resources: [
                .process("Resources"),
                .process("Presets"),
            ]
        ),
    ]
)
