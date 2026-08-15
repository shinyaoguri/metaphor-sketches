import Foundation
import metaphor
import simd

/// 地層（strata）のハイトフィールド。
///
/// 設計方針:
/// - **静的成分と動的成分を分ける**。多層ノイズ（地形・稜線・浸食チャンネル）は
///   `generate()` で一度だけ計算し、`update()` は「静的成分をシーンの profile で
///   合成し直す」だけにする。16k 頂点 × 60fps で fBm を引き直すと CPU が律速する
///   （2 パス目の法線計算も含めて毎フレーム 2 周だけで済ませる）。
/// - 法線は隣接高さの中央差分で作る。ライブラリに法線再計算の API は無い。
@MainActor
final class Terrain {
    /// 一辺の頂点数。
    let gridSize: Int
    /// ワールド座標での一辺の長さ。
    let extent: Float

    private let mesh: DynamicMesh

    // MARK: - 静的成分（generate() でのみ書き換わる）

    /// 基本地形。0..1。
    private var base: [Float]
    /// 稜線（ridged multifractal 風）。0..1。谷を鋭く、尾根を細くする。
    private var ridge: [Float]
    /// 浸食チャンネル。0..1。大きいところほど削れる。
    private var channel: [Float]

    // MARK: - 動的成分

    private var heights: [Float]
    private(set) var minHeight: Float = 0
    private(set) var maxHeight: Float = 1

    /// 地層の色。低い順に暗い岩 → 明るい砂岩。
    private static let palette: [SIMD3<Float>] = [
        SIMD3(0.16, 0.14, 0.18),
        SIMD3(0.33, 0.22, 0.22),
        SIMD3(0.56, 0.34, 0.24),
        SIMD3(0.76, 0.52, 0.31),
        SIMD3(0.90, 0.74, 0.50),
        SIMD3(0.97, 0.93, 0.84),
    ]

    init(mesh: DynamicMesh, gridSize: Int, extent: Float, seed: UInt64) {
        self.mesh = mesh
        self.gridSize = gridSize
        self.extent = extent

        let count = gridSize * gridSize
        base = [Float](repeating: 0, count: count)
        ridge = [Float](repeating: 0, count: count)
        channel = [Float](repeating: 0, count: count)
        heights = [Float](repeating: 0, count: count)

        generate(seed: seed)
        buildTopology()
    }

    // MARK: - 生成

    /// 静的成分を作り直す。シーンが一巡したときなどに呼ぶと地形が入れ替わる。
    func generate(seed: UInt64) {
        var terrainNoise = NoiseGenerator(seed: seed)
        terrainNoise.octaves = 5
        terrainNoise.falloff = 0.5

        var ridgeNoise = NoiseGenerator(seed: seed &+ 7919)
        ridgeNoise.octaves = 3
        ridgeNoise.falloff = 0.55

        var channelNoise = NoiseGenerator(seed: seed &+ 104_729)
        channelNoise.octaves = 2
        channelNoise.falloff = 0.6

        let n = gridSize
        for j in 0..<n {
            for i in 0..<n {
                let idx = j * n + i
                let u = Float(i) / Float(n - 1)
                let v = Float(j) / Float(n - 1)

                base[idx] = terrainNoise.noise(u * 3.1, v * 3.1)

                // 1 - |2x-1| で尾根を立てる（値ノイズの山を折り返して鋭い稜線にする）
                let r = ridgeNoise.noise(u * 5.7 + 11.3, v * 5.7 + 4.1)
                ridge[idx] = 1 - abs(r * 2 - 1)

                channel[idx] = channelNoise.noise(u * 2.3 + 31.7, v * 2.3 + 19.9)
            }
        }

        // 縁を落として「切り出された地層のブロック」に見せる。
        // 縁が立ったままだと視界の外へ地面が突き抜けて絵が破綻する。
        for j in 0..<n {
            for i in 0..<n {
                let idx = j * n + i
                let u = Float(i) / Float(n - 1)
                let v = Float(j) / Float(n - 1)
                let edge = min(min(u, 1 - u), min(v, 1 - v))
                let falloff = smoothStep(0.0, 0.18, edge)
                base[idx] *= falloff
                ridge[idx] *= falloff
            }
        }
    }

    /// 頂点とインデックスを一度だけ作る。以降は `setVertex` / `setNormal` /
    /// `setColor` で中身だけ差し替える。
    private func buildTopology() {
        let n = gridSize
        mesh.clear()

        for j in 0..<n {
            for i in 0..<n {
                mesh.addColor(SIMD4<Float>(1, 1, 1, 1))
                mesh.addNormal(SIMD3<Float>(0, 1, 0))
                mesh.addVertex(worldX(i), 0, worldZ(j))
            }
        }

        for j in 0..<(n - 1) {
            for i in 0..<(n - 1) {
                let a = UInt32(j * n + i)
                let b = UInt32(j * n + i + 1)
                let c = UInt32((j + 1) * n + i)
                let d = UInt32((j + 1) * n + i + 1)
                mesh.addTriangle(a, c, b)
                mesh.addTriangle(b, c, d)
            }
        }
    }

    // MARK: - 更新

    /// シーンの profile と外部入力から今フレームの高さ・法線・頂点カラーを作る。
    ///
    /// - Parameters:
    ///   - profile: 補間済みのシーン profile。
    ///   - drive: カメラ由来の駆動値。
    ///   - t: スケッチ開始からの経過時間（秒）。
    func update(profile: SceneProfile, drive: SenseDrive, t: Float) {
        let n = gridSize
        let elevation = profile.elevation * (1 + drive.energy * profile.energyResponse)
        let erosion = profile.erosion
        let terrace = profile.terrace
        let bandHeight = max(elevation * 0.06, 0.001)

        // うねりは「安価な周期項」に徹する。ここでノイズを引くと律速する。
        let rippleK = 6.0 / max(extent, 1)
        let ripplePhase = t * profile.rippleSpeed

        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude

        for j in 0..<n {
            let z = worldZ(j)
            for i in 0..<n {
                let idx = j * n + i
                let x = worldX(i)

                var h = base[idx] * elevation
                h += ridge[idx] * profile.ridge * elevation
                h -= channel[idx] * erosion * elevation

                if profile.rippleAmount > 0 {
                    let w = sinf(ripplePhase + (x + z) * rippleK)
                        + 0.5 * sinf(ripplePhase * 0.63 - (x - z) * rippleK * 1.7)
                    h += w * profile.rippleAmount * elevation
                }

                if terrace > 0 {
                    let stepped = (h / bandHeight).rounded(.down) * bandHeight
                    h += (stepped - h) * terrace
                }

                heights[idx] = h
                if h < lo { lo = h }
                if h > hi { hi = h }
            }
        }

        minHeight = lo
        maxHeight = hi
        let span = max(hi - lo, 0.0001)

        // 高さの単位あたりの水平距離。中央差分から法線を作るのに使う。
        let step = extent / Float(n - 1)
        let bands = max(profile.bands, 1)
        let tintShift = drive.tint

        for j in 0..<n {
            for i in 0..<n {
                let idx = j * n + i
                let h = heights[idx]

                // Y は画面下向きが正（metaphor の 3D 既定と揃える）ため、
                // 高さは -Y 方向へ伸ばす。
                mesh.setVertex(idx, SIMD3<Float>(worldX(i), -h, worldZ(j)))

                let hl = heights[j * n + max(i - 1, 0)]
                let hr = heights[j * n + min(i + 1, n - 1)]
                let hd = heights[max(j - 1, 0) * n + i]
                let hu = heights[min(j + 1, n - 1) * n + i]
                let dx = (hr - hl) / (2 * step)
                let dz = (hu - hd) / (2 * step)
                // 面 P=(x, -h, z) の接ベクトル (1,-hx,0) × (0,-hz,1) = (-hx,-1,-hz)。
                // 高さを -Y へ伸ばしているので法線も -Y 側（画面上向き）を向く。
                // ここを (dx, 1, dz) にすると光を裏から受けて全面が真っ黒になる。
                mesh.setNormal(idx, normalize(SIMD3<Float>(-dx, -1, -dz)))

                let tNorm = (h - lo) / span
                mesh.setColor(idx, stratumColor(tNorm, bands: bands, profile: profile, tint: tintShift))
            }
        }
    }

    /// 高さ 0..1 から地層の色を作る。バンド境界を暗くして「層」に見せる。
    private func stratumColor(
        _ t: Float, bands: Int, profile: SceneProfile, tint: Float
    ) -> SIMD4<Float> {
        let clamped = min(max(t, 0), 1)
        let scaled = clamped * Float(Terrain.palette.count - 1)
        let i0 = min(Int(scaled), Terrain.palette.count - 2)
        let frac = scaled - Float(i0)
        var rgb = mix(Terrain.palette[i0], Terrain.palette[i0 + 1], t: frac)

        // バンド境界（層の切れ目）を暗くする
        let phase = clamped * Float(bands)
        let inBand = phase - phase.rounded(.down)
        let toEdge = min(inBand, 1 - inBand) * 2
        let shade = 1 - (1 - toEdge) * 0.45 * profile.bandContrast
        rgb *= shade

        // 外部入力（カメラ）の色温度シフト。暖色 ←→ 寒色。
        rgb.x *= 1 + tint * 0.25
        rgb.z *= 1 - tint * 0.25

        return SIMD4<Float>(min(rgb.x, 1), min(rgb.y, 1), min(rgb.z, 1), 1)
    }

    /// 描画。fill 色は頂点カラーに乗算されるため白で呼ぶ。
    func draw(in sketch: Sketch) {
        sketch.fill(255, 255, 255)
        sketch.noStroke()
        sketch.dynamicMesh(mesh)
    }

    var vertexCount: Int { gridSize * gridSize }
    var triangleCount: Int { (gridSize - 1) * (gridSize - 1) * 2 }

    // MARK: - 座標

    private func worldX(_ i: Int) -> Float {
        (Float(i) / Float(gridSize - 1) - 0.5) * extent
    }

    private func worldZ(_ j: Int) -> Float {
        (Float(j) / Float(gridSize - 1) - 0.5) * extent
    }
}

// MARK: - 小さな数値ヘルパ

func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
    a + (b - a) * t
}

func smoothStep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = min(max((x - edge0) / max(edge1 - edge0, 1e-6), 0), 1)
    return t * t * (3 - 2 * t)
}
