import Foundation
import simd

/// 1 ステージ分の仕様。**アセットの名前とゲームの難度だけ**を持ち、実体は持たない。
///
/// この作品の主題は「シーンごとにアセットが入れ替わる」こと（[#571](https://github.com/shinyaoguri/metaphor/issues/571)
/// の "Scene = 寿命境界" を判定するため）。1 本目 `0815-strata` はシーンが値の束
/// （profile）だけを持ち、リソースは全シーンで共有していたので判定材料にならなかった。
struct StageSpec {
    let id: String
    let label: String

    // ステージ固有アセット（enter でロードし exit で解放する）
    let obstacleModel: String
    let floorImage: String
    let ambienceSound: String
    /// 背景動画。重いので 1 ステージだけに付ける（Video 経路の検証用）。
    let backdropVideo: String?

    // 見た目
    let background: SIMD3<Float>
    let obstacleColor: SIMD3<Float>
    let coreColor: SIMD3<Float>
    let ambient: Float
    let fogTint: SIMD3<Float>

    // ゲーム
    let coreCount: Int
    let obstacleCount: Int
    let obstacleSpeed: Float
    let obstacleScale: Float
    let timeLimit: Float

    static let all: [StageSpec] = [hull, reactor, vent]

    /// 沈んだ船体。広く、障害はゆっくり。
    static let hull = StageSpec(
        id: "hull",
        label: "I. HULL",
        obstacleModel: "rock_hull",
        floorImage: "floor_hull",
        ambienceSound: "amb_hull",
        backdropVideo: "backdrop_hull",
        background: SIMD3(6, 14, 20),
        obstacleColor: SIMD3(96, 124, 132),
        coreColor: SIMD3(120, 232, 224),
        ambient: 96,
        fogTint: SIMD3(18, 52, 64),
        coreCount: 6,
        obstacleCount: 10,
        obstacleSpeed: 42,
        obstacleScale: 78,
        timeLimit: 70
    )

    /// 炉室。柱が林立し、速い。
    static let reactor = StageSpec(
        id: "reactor",
        label: "II. REACTOR",
        obstacleModel: "pillar_reactor",
        floorImage: "floor_reactor",
        ambienceSound: "amb_reactor",
        backdropVideo: nil,
        background: SIMD3(18, 8, 5),
        obstacleColor: SIMD3(188, 116, 62),
        coreColor: SIMD3(255, 196, 96),
        ambient: 88,
        fogTint: SIMD3(78, 30, 12),
        coreCount: 7,
        obstacleCount: 13,
        obstacleSpeed: 66,
        obstacleScale: 96,
        timeLimit: 65
    )

    /// 噴出孔。破片が速く漂い、視界が悪い。
    static let vent = StageSpec(
        id: "vent",
        label: "III. VENT",
        obstacleModel: "shard_vent",
        floorImage: "floor_vent",
        ambienceSound: "amb_vent",
        backdropVideo: nil,
        background: SIMD3(10, 8, 22),
        obstacleColor: SIMD3(150, 128, 226),
        coreColor: SIMD3(214, 168, 255),
        ambient: 80,
        fogTint: SIMD3(40, 30, 84),
        coreCount: 8,
        obstacleCount: 16,
        obstacleSpeed: 92,
        obstacleScale: 70,
        timeLimit: 60
    )
}
