import Foundation
import metaphor
import simd

/// 1 シーン分の「見た目と挙動のパラメータ一式」。
///
/// シーンを「描画コードの分岐」ではなく **profile（値の束）** として持ち、
/// 遷移は 2 つの profile の補間で行う。地形を 2 枚描いてクロスフェードすると
/// 頂点更新が倍になるため（16k 頂点 × 2）、この作品では値の補間を採る。
struct SceneProfile {
    // 地形
    var elevation: Float
    var ridge: Float
    var erosion: Float
    var terrace: Float
    var rippleAmount: Float
    var rippleSpeed: Float
    var bands: Int
    var bandContrast: Float
    /// カメラ入力のエネルギーを隆起へ効かせる強さ。
    var energyResponse: Float

    // マテリアル・ライト
    var metallic: Float
    var roughness: Float
    /// アンビエント強度（0..255。`ambientLight()` のレンジ）。
    ///
    /// metaphor の PBR は IBL を持たず、直接光が `albedo / π` で入る。
    /// さらに `directionalLight` に強度引数が無い（固定 1.0）ため、
    /// キーライト 1 灯だけでは物理的に暗くなる。ここを高めに取り、
    /// fill / rim を足して絵を成立させている（所見は README に記録）。
    var ambient: Float
    /// キーライトの向き（光が進む向き。y が正なら上から差す）。
    var lightDirection: SIMD3<Float>
    /// フィルライトの強さ 0..1。キーの反対側から寒色で起こす。
    var fill: Float
    /// リムライトの強さ 0..1。低い角度から暖色で稜線を拾う。
    var rim: Float
    var background: SIMD3<Float>

    // カメラ
    var cameraRadius: Float
    var cameraHeight: Float
    var cameraLookHeight: Float
    var cameraOrbitSpeed: Float
    var fov: Float

    // ポストプロセス
    var bloom: Float
    var bloomThreshold: Float
    var vignette: Float
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var temperature: Float
}

extension SceneProfile {
    /// 2 つの profile を線形補間する。`bands` だけは整数なので近い側へ寄せる。
    static func blend(_ a: SceneProfile, _ b: SceneProfile, _ t: Float) -> SceneProfile {
        func f(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        return SceneProfile(
            elevation: f(a.elevation, b.elevation),
            ridge: f(a.ridge, b.ridge),
            erosion: f(a.erosion, b.erosion),
            terrace: f(a.terrace, b.terrace),
            rippleAmount: f(a.rippleAmount, b.rippleAmount),
            rippleSpeed: f(a.rippleSpeed, b.rippleSpeed),
            bands: t < 0.5 ? a.bands : b.bands,
            bandContrast: f(a.bandContrast, b.bandContrast),
            energyResponse: f(a.energyResponse, b.energyResponse),
            metallic: f(a.metallic, b.metallic),
            roughness: f(a.roughness, b.roughness),
            ambient: f(a.ambient, b.ambient),
            lightDirection: normalize(mix(a.lightDirection, b.lightDirection, t: t)),
            fill: f(a.fill, b.fill),
            rim: f(a.rim, b.rim),
            background: mix(a.background, b.background, t: t),
            cameraRadius: f(a.cameraRadius, b.cameraRadius),
            cameraHeight: f(a.cameraHeight, b.cameraHeight),
            cameraLookHeight: f(a.cameraLookHeight, b.cameraLookHeight),
            cameraOrbitSpeed: f(a.cameraOrbitSpeed, b.cameraOrbitSpeed),
            fov: f(a.fov, b.fov),
            bloom: f(a.bloom, b.bloom),
            bloomThreshold: f(a.bloomThreshold, b.bloomThreshold),
            vignette: f(a.vignette, b.vignette),
            brightness: f(a.brightness, b.brightness),
            contrast: f(a.contrast, b.contrast),
            saturation: f(a.saturation, b.saturation),
            temperature: f(a.temperature, b.temperature)
        )
    }
}

// MARK: - 4 つのシーン

enum Scenes {
    /// 隆起。地形が下から立ち上がり、稜線が伸びる。
    static let formation = SceneProfile(
        elevation: 210, ridge: 0.55, erosion: 0.05, terrace: 0,
        rippleAmount: 0.06, rippleSpeed: 0.35, bands: 7, bandContrast: 0.35,
        energyResponse: 0.5,
        metallic: 0.05, roughness: 0.75, ambient: 108,
        lightDirection: normalize(SIMD3<Float>(0.35, 1, -0.4)),
        fill: 0.55, rim: 0.5,
        background: SIMD3(0.03, 0.035, 0.05),
        cameraRadius: 920, cameraHeight: 430, cameraLookHeight: -10,
        cameraOrbitSpeed: 0.055, fov: .pi / 3.4,
        bloom: 0.35, bloomThreshold: 0.78, vignette: 0.22,
        brightness: 0.04, contrast: 1.05, saturation: 1.05, temperature: 0.1
    )

    /// 浸食。谷が刻まれ、色が抜けて寒色へ寄る。
    static let erosion = SceneProfile(
        elevation: 190, ridge: 0.3, erosion: 0.62, terrace: 0,
        rippleAmount: 0.03, rippleSpeed: 0.9, bands: 9, bandContrast: 0.5,
        energyResponse: 0.75,
        metallic: 0.1, roughness: 0.85, ambient: 92,
        lightDirection: normalize(SIMD3<Float>(-0.5, 1, -0.25)),
        fill: 0.7, rim: 0.35,
        background: SIMD3(0.025, 0.03, 0.045),
        cameraRadius: 800, cameraHeight: 330, cameraLookHeight: -20,
        cameraOrbitSpeed: 0.11, fov: .pi / 3.0,
        bloom: 0.6, bloomThreshold: 0.68, vignette: 0.34,
        brightness: 0.0, contrast: 1.18, saturation: 0.72, temperature: -0.25
    )

    /// 地層。段丘化して層の縞が主役になる。
    static let strata = SceneProfile(
        elevation: 240, ridge: 0.2, erosion: 0.2, terrace: 0.9,
        rippleAmount: 0.01, rippleSpeed: 0.2, bands: 16, bandContrast: 0.95,
        energyResponse: 0.25,
        metallic: 0.2, roughness: 0.55, ambient: 104,
        lightDirection: normalize(SIMD3<Float>(0.15, 1, -0.75)),
        fill: 0.45, rim: 0.65,
        background: SIMD3(0.04, 0.032, 0.03),
        cameraRadius: 700, cameraHeight: 260, cameraLookHeight: -60,
        cameraOrbitSpeed: 0.035, fov: .pi / 3.8,
        bloom: 0.25, bloomThreshold: 0.85, vignette: 0.2,
        brightness: 0.05, contrast: 1.12, saturation: 1.15, temperature: 0.2
    )

    /// 沈静。低負荷で遠景をゆっくり周回する。無人稼働の「谷」に相当する。
    static let dormant = SceneProfile(
        elevation: 120, ridge: 0.35, erosion: 0.1, terrace: 0.25,
        rippleAmount: 0.02, rippleSpeed: 0.12, bands: 6, bandContrast: 0.25,
        energyResponse: 0.15,
        metallic: 0.02, roughness: 0.9, ambient: 82,
        lightDirection: normalize(SIMD3<Float>(0.6, 1, 0.2)),
        fill: 0.6, rim: 0.3,
        background: SIMD3(0.015, 0.017, 0.024),
        cameraRadius: 1150, cameraHeight: 560, cameraLookHeight: 0,
        cameraOrbitSpeed: 0.02, fov: .pi / 3.6,
        bloom: 0.15, bloomThreshold: 0.9, vignette: 0.3,
        brightness: -0.02, contrast: 1.0, saturation: 0.85, temperature: -0.05
    )

    static let all: [(name: String, profile: SceneProfile)] = [
        ("formation", formation),
        ("erosion", erosion),
        ("strata", strata),
        ("dormant", dormant),
    ]
}

// MARK: - シーンの巡回と遷移

/// シーンの保持時間と遷移を管理する。
///
/// **ライブラリに相当機能が無いため作品側で手書きしている**（metaphor には
/// Scene / 遷移 / cue / スケジューラが無い。Epic #415 の設計根拠として
/// ここで踏んだ痛みを README と Issue に残す）。
@MainActor
final class SceneDirector {
    private let entries: [(name: String, profile: SceneProfile)]
    /// 各シーンの保持時間（秒）。`@Param` から実行中に変えられる。
    var holdSeconds: Float
    /// 遷移にかける時間（秒）。
    let transitionSeconds: Float

    private(set) var currentIndex: Int = 0
    private(set) var fromIndex: Int = 0
    /// 遷移の進行。1 で遷移完了（= 定常）。
    private(set) var transition: Float = 1
    private(set) var elapsedInScene: Float = 0
    /// シーンが切り替わった回数。無人稼働で巡回が止まっていないかの指標。
    private(set) var switchCount: Int = 0

    init(
        entries: [(name: String, profile: SceneProfile)],
        holdSeconds: Float,
        transitionSeconds: Float
    ) {
        self.entries = entries
        self.holdSeconds = holdSeconds
        self.transitionSeconds = transitionSeconds
    }

    var currentName: String { entries[currentIndex].name }
    var isTransitioning: Bool { transition < 1 }

    /// 補間済みの profile。
    var profile: SceneProfile {
        guard transition < 1 else { return entries[currentIndex].profile }
        // ease-in-out（遷移の入り口と出口を寝かせる）
        let t = transition * transition * (3 - 2 * transition)
        return SceneProfile.blend(entries[fromIndex].profile, entries[currentIndex].profile, t)
    }

    func update(dt: Float) {
        elapsedInScene += dt
        if transition < 1 {
            transition = min(1, transition + dt / max(transitionSeconds, 0.001))
        }
        if elapsedInScene >= holdSeconds {
            advance()
        }
    }

    /// 次のシーンへ。自律タイマー用。
    func advance() {
        go(to: (currentIndex + 1) % entries.count)
    }

    /// 外部（OSC）からの指定。範囲外は無視する。
    func go(to index: Int) {
        guard entries.indices.contains(index), index != currentIndex else {
            // 同じシーンの指定はタイマーだけ延ばす（外部からの「留めておけ」に使える）
            if entries.indices.contains(index), index == currentIndex {
                elapsedInScene = 0
            }
            return
        }
        fromIndex = currentIndex
        currentIndex = index
        transition = 0
        elapsedInScene = 0
        switchCount += 1
    }

    func index(ofName name: String) -> Int? {
        entries.firstIndex { $0.name == name }
    }
}
