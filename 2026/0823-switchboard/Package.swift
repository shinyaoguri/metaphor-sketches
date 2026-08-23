// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "0823-switchboard",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // metaphor への依存。リリース参照の from: "X.Y.Z" は「X.Y.Z 以上・次の major 未満」を
        // 許容する（0.x では minor 更新にも破壊的変更が入りうる）。バージョンを固定したい
        // 場合は .upToNextMinor(from:) や exact: に書き換える。
        .package(url: "https://github.com/shinyaoguri/metaphor.git", from: "0.13.0"),
        // Syphon 出力は metaphor#792 で本体から分離され、別パッケージになった。
        // これを足さないと .syphon(name:) も METAPHOR_SYPHON_NAME も効かない。
        .package(url: "https://github.com/shinyaoguri/metaphor-syphon.git", from: "0.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "Sketch0823Switchboard",
            dependencies: [
                .product(name: "metaphor", package: "metaphor"),
                .product(name: "MetaphorSyphon", package: "metaphor-syphon"),
            ],
            resources: [
                .process("Resources"),
                .process("Presets"),
            ]
        ),
    ]
)
