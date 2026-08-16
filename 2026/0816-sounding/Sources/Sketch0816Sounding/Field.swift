import Foundation
import metaphor
import simd

// 測深される地形。
//
// `GKNoiseWrapper` の場をグリッドで読み、深度帯の色と等深線に変える。
// 音の帯域エネルギーが毎フレーム `NoiseConfig` を書き換えるので、
// 「別モジュールの実時間の値が、このモジュールの設定を駆動する」という
// この作品の主題はここに集まっている。
//
// **非自明な注意**: `GKNoiseWrapper.config` の setter は GKNoise ソースを作り直す。
// つまり `add` / `multiply` / `invert` / `applyTurbulence` の合成は config を書いた
// 瞬間にすべて捨てられる。ライブラリのソースコメントには書いてあるが、
// AI が読む `llms.txt` 側には落ちている（metaphor#786）。
// ここではその挙動を逆手に取り、毎フレーム「config を書く → 乱れを掛け直す」の順で
// 組み立てている。累積しないので、同じ入力なら同じ地形になる。
@MainActor
final class Field {

    /// グリッドの列数。等深線の本数と 1 フレームの負荷を決める。
    let cols: Int
    /// グリッドの行数。
    let rows: Int

    /// 深度（row-major、0…1）。`sampleGrid` の結果を `stretch()` で引き伸ばしたもの。
    private(set) var values: [Float]

    /// 現在の海底のシード。一定間隔で変わり、別の海底になる。
    private(set) var seed: Int32

    /// 直近に適用した設定。HUD と probe に出す。
    private(set) var frequency: Float = 1.0
    private(set) var persistence: Float = 0.5
    private(set) var turbulence: Float = 0.0
    private(set) var drift: SIMD2<Float> = .zero

    /// 1 フレームの内訳（ミリ秒）。組み合わせの負荷がどこに出るかを見るための実測。
    ///
    /// `config` の setter は GKNoise ソースを作り直し、`sampleGrid` は毎回
    /// `GKNoiseMap` を作る。「毎フレーム音で設定を書き換える」という使い方の代償が
    /// ここに出る。
    private(set) var configMilliseconds: Double = 0
    private(set) var sampleMilliseconds: Double = 0

    /// 伸長前に観測した値域（EMA で均したもの）と、その幅。
    private var observedLow: Float = .nan
    private var observedHigh: Float = .nan
    private(set) var contrast: Float = 1

    /// 場のサンプル間隔（`sampleScale`）。グリッド 1 マスあたりのノイズ空間の距離。
    ///
    /// **`sample(x:y:)` で同じ場を読み直そうとしないこと。** この 2 つの入口は同じ
    /// 座標系を共有していない（`N8` / `N9` に実測がある）。この作品は `sampleGrid` の
    /// 出力だけを見て、色も等深線もそこから作る。だから絵の中では矛盾しない。
    static let sampleSpacing: Double = 0.02

    private let noise: GKNoiseWrapper

    init(noise: GKNoiseWrapper, cols: Int, rows: Int, seed: Int32) {
        self.noise = noise
        self.cols = cols
        self.rows = rows
        self.seed = seed
        self.values = [Float](repeating: 0, count: cols * rows)
    }

    // MARK: - 音 → 地形

    /// 帯域エネルギーで地形を作り直す。
    ///
    /// - Parameters:
    ///   - bass: 低域（大局的なうねりの粗さ）
    ///   - mids: 中域（場の流れ）
    ///   - highs: 高域（縁のざらつき）
    ///   - drift: 累積した流れ。呼び出し側が時間積分して渡す
    func update(bass: Float, mids: Float, highs: Float, drift: SIMD2<Float>) {
        // 無音・クリップ・NaN をここで殺す。音の経路から来た値をそのまま
        // ノイズの設定へ流すと、1 つの NaN で場全体が消える。
        let low = Self.sanitize(bass)
        let mid = Self.sanitize(mids)
        let high = Self.sanitize(highs)

        // 何をどれに割り当てるかは実測で決めた。ドローンが鳴りっぱなしなので低域は
        // ほぼ一定で、そこへ frequency を繋ぐと地形の粗さが動かない。
        // 動きのあるアルペジオ（中域）を地形の粗さに、低域は起伏の深さに回す。
        frequency = 1.4 + mid * 1.8
        persistence = 0.40 + low * 0.25
        turbulence = high * 0.55
        self.drift = drift

        var config = NoiseConfig(
            octaves: 5,
            frequency: Double(frequency),
            lacunarity: 2.0,
            seed: seed,
            persistence: Double(persistence),
            normalized: true,
            voronoiDistanceEnabled: true,
            sampleScale: SIMD2(Self.sampleSpacing, Self.sampleSpacing),
            origin: SIMD2(Double(drift.x), Double(drift.y))
        )
        config.normalized = true

        // 順序が意味を持つ。config を書くとソースが作り直されるので、
        // 乱れは必ずそのあとで掛ける（前に掛けると黙って消える）。
        let configStarted = DispatchTime.now().uptimeNanoseconds
        noise.config = config
        if turbulence > 0.001 {
            noise.applyTurbulence(
                frequency: 2.4,
                power: Double(turbulence),
                roughness: 3,
                seed: seed &+ 17
            )
        }
        let sampleStarted = DispatchTime.now().uptimeNanoseconds
        values = noise.sampleGrid(width: cols, height: rows)
        let finished = DispatchTime.now().uptimeNanoseconds

        configMilliseconds = Double(sampleStarted - configStarted) / 1_000_000
        sampleMilliseconds = Double(finished - sampleStarted) / 1_000_000

        stretch()
    }

    /// 深度を伸長する。海図が「その海域の最深と最浅で色を割り当てる」のと同じ。
    ///
    /// これが要るのは、正規化した GKNoise の値域が設定次第で大きく変わるため。
    /// `frequency` を下げて狭い窓を見ると値が 0.5 付近へ集まり、固定の等深線には
    /// 1 本も掛からなくなる（実際に等深線 0 本の絵になった）。
    /// 観測した最小・最大で引き伸ばせば、どの設定でも地図として読める。
    /// 範囲は EMA で均す — フレームごとに伸長率が跳ねると画面が明滅する。
    private func stretch() {
        var low = Float.greatestFiniteMagnitude
        var high = -Float.greatestFiniteMagnitude
        for value in values {
            low = min(low, value)
            high = max(high, value)
        }
        guard low.isFinite, high.isFinite else { return }

        if observedLow.isNaN {
            observedLow = low
            observedHigh = high
        } else {
            let smoothing: Float = 0.9
            observedLow = observedLow * smoothing + low * (1 - smoothing)
            observedHigh = observedHigh * smoothing + high * (1 - smoothing)
        }

        let span = max(observedHigh - observedLow, 1e-4)
        contrast = span
        for i in values.indices {
            values[i] = min(max((values[i] - observedLow) / span, 0), 1)
        }
    }

    /// 海底を入れ替える。呼ぶたびに別の地形になる。
    func reseed(_ newSeed: Int32) {
        seed = newSeed
    }

    /// 音から来た値を [0, 1] の有限値へ落とす。
    static func sanitize(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    // MARK: - 読み出し

    /// グリッド座標の深度。範囲外は縁の値を返す。
    func value(atCol col: Int, row: Int) -> Float {
        let c = min(max(col, 0), cols - 1)
        let r = min(max(row, 0), rows - 1)
        return values[r * cols + c]
    }

    // MARK: - 等深線

    /// 指定した深度の等値線を線分の列として返す。
    ///
    /// 座標はグリッド単位（0…cols-1, 0…rows-1）。描画側で画面へ写す。
    /// marching squares。曖昧なケース（対角の 5 と 10）は中心値で解く。
    func contour(at level: Float, into segments: inout [SIMD4<Float>]) {
        guard cols > 1, rows > 1 else { return }

        for row in 0..<(rows - 1) {
            for col in 0..<(cols - 1) {
                let va = values[row * cols + col]
                let vb = values[row * cols + col + 1]
                let vc = values[(row + 1) * cols + col + 1]
                let vd = values[(row + 1) * cols + col]

                var code = 0
                if va >= level { code |= 1 }
                if vb >= level { code |= 2 }
                if vc >= level { code |= 4 }
                if vd >= level { code |= 8 }
                if code == 0 || code == 15 { continue }

                let x = Float(col)
                let y = Float(row)
                // 各辺の交点。t は線形補間で、等深線が階段に見えないための要。
                let top = SIMD2(x + Self.lerpT(va, vb, level), y)
                let right = SIMD2(x + 1, y + Self.lerpT(vb, vc, level))
                let bottom = SIMD2(x + Self.lerpT(vd, vc, level), y + 1)
                let left = SIMD2(x, y + Self.lerpT(va, vd, level))

                switch code {
                case 1, 14: segments.append(Self.seg(left, top))
                case 2, 13: segments.append(Self.seg(top, right))
                case 3, 12: segments.append(Self.seg(left, right))
                case 4, 11: segments.append(Self.seg(right, bottom))
                case 6, 9: segments.append(Self.seg(top, bottom))
                case 7, 8: segments.append(Self.seg(left, bottom))
                case 5, 10:
                    // 鞍点。中心の平均で、どちらの繋ぎ方かを決める。
                    let center = (va + vb + vc + vd) * 0.25
                    let joined = (center >= level) == (code == 5)
                    if joined {
                        segments.append(Self.seg(left, top))
                        segments.append(Self.seg(right, bottom))
                    } else {
                        segments.append(Self.seg(left, bottom))
                        segments.append(Self.seg(top, right))
                    }
                default: break
                }
            }
        }
    }

    private static func seg(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD4<Float> {
        SIMD4(a.x, a.y, b.x, b.y)
    }

    /// 2 つの格子点の間で level を横切る位置（0…1）。
    private static func lerpT(_ from: Float, _ to: Float, _ level: Float) -> Float {
        let d = to - from
        guard abs(d) > 1e-6 else { return 0.5 }
        return min(max((level - from) / d, 0), 1)
    }

    // MARK: - 深度の配色

    /// 海図の配色。深い側が濃紺、浅い側が砂色。
    static let depthStops: [(Float, SIMD3<Float>)] = [
        (0.00, SIMD3(6, 14, 34)),
        (0.32, SIMD3(16, 52, 92)),
        (0.50, SIMD3(26, 96, 116)),
        (0.66, SIMD3(64, 142, 134)),
        (0.80, SIMD3(140, 180, 152)),
        (1.00, SIMD3(214, 214, 184)),
    ]

    /// 深度値を色へ写す。0…255 のチャンネル値で返す（`fill` のスケールに合わせる）。
    static func depthColor(_ value: Float) -> SIMD3<Float> {
        let v = min(max(value, 0), 1)
        var previous = depthStops[0]
        for stop in depthStops.dropFirst() {
            if v <= stop.0 {
                let span = stop.0 - previous.0
                let t = span > 0 ? (v - previous.0) / span : 0
                return previous.1 + (stop.1 - previous.1) * t
            }
            previous = stop
        }
        return depthStops[depthStops.count - 1].1
    }
}
