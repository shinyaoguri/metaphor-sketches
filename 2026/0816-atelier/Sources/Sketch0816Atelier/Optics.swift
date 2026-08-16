import Foundation
import simd
import metaphor

// 解析側の道具立て。
//
// この作品の判定はすべて「手で解いた期待値」と「焼き上がった画素」の突き合わせで行う。
// そのためにここへ二つを置く:
//
//   1. `Optics`  — カメラと投影を metaphor と同じ式で自前に組み直したもの
//   2. `Plate`   — Blinn-Phong の陰影を、シェーダーと同じ式で自前に解いたもの
//
// **どちらも metaphor を呼ばない。** 呼んでしまうと「metaphor と metaphor を比べる」ことに
// なり、両方が同じだけ狂っていても PASS になる。物差しは外から持ち込む。
//
// 式の出どころ（v0.9.0 の実装。作品を別バージョンへ載せ替えるときはここを読み直すこと）:
//   Canvas3D+Frame.swift  — 既定カメラを毎フレーム再設定する規約
//   Canvas3D.swift        — computeViewProjection（flipY * proj * view）
//   Math.swift            — lookAt / perspectiveFov / orthographic
//   Shaders/Metal/MetaphorLighting.h — calculateBlinnPhongLighting

// MARK: - 画面の矩形

/// 画面上の矩形。左上原点・ピクセル単位で、`pixels` の添字と一致する前提。
struct Rect {
    var x: Float
    var y: Float
    var w: Float
    var h: Float

    var right: Float { x + w }
    var bottom: Float { y + h }
    var cx: Float { x + w / 2 }
    var cy: Float { y + h / 2 }

    /// 中心と半径から作る（採寸の関心域を切るときに使う）。
    static func around(_ cx: Float, _ cy: Float, _ halfW: Float, _ halfH: Float) -> Rect {
        Rect(x: cx - halfW, y: cy - halfH, w: halfW * 2, h: halfH * 2)
    }
}

// MARK: - 判定

/// 1 件の照合結果。
enum Verdict {
    /// 期待どおり。付随する文字列は実測の要約。
    case pass(String)
    /// 期待に反した。文字列は「実測 → 期待」を人が読める形で。
    case fail(String)
    /// 自動判定に落とせず、目視に回すもの。
    case look(String)

    var isFail: Bool { if case .fail = self { return true }; return false }
    var isPass: Bool { if case .pass = self { return true }; return false }

    /// 機械が読む語。**`PASS` / `FAIL` / `LOOK` から変えないこと** —
    /// `verification/upstream.json` の `verdictPattern` と
    /// `.claude/skills/upstream-recheck/scripts/recheck.py` がこの語で
    /// 「直ったか」を判定する（recheck.py は `now == "PASS"` を見ている）。
    var token: String {
        switch self {
        case .pass: return "PASS"
        case .fail: return "FAIL"
        case .look: return "LOOK"
        }
    }

    /// 画面の講評欄に出す語。デッサンの講評の言い方に寄せる。
    var mark: String {
        switch self {
        case .pass: return "良"
        case .fail: return "直し"
        case .look: return "要確認"
        }
    }

    var detail: String {
        switch self {
        case .pass(let s), .fail(let s), .look(let s): return s
        }
    }
}

/// 判定 1 件。ID は場面の頭文字（F/V/D/S/H）＋通番。
struct Finding {
    let id: String
    let title: String
    let verdict: Verdict

    init(_ id: String, _ title: String, _ verdict: Verdict) {
        self.id = id
        self.title = title
        self.verdict = verdict
    }

    /// 標準出力とログに出す 1 行。`tools/probe.sh` と upstream-recheck がこの形を読む。
    var line: String { "[\(id)] \(verdict.token) \(title): \(verdict.detail)" }
}

// MARK: - 期待との突き合わせ

/// 実測と期待を突き合わせ、**差を必ず数値で残す**。
///
/// 真偽値だけを返さないのは、あとで issue に貼るときに数字がそのまま証拠になるため。
func expect(_ actual: Float, _ expected: Float, tol: Float,
            what: String, unit: String = "px") -> Verdict {
    let d = actual - expected
    let body = "\(what) 実測=\(f2(actual))\(unit) 期待=\(f2(expected))\(unit) 差=\(f2(d))\(unit) 許容=±\(f2(tol))\(unit)"
    return abs(d) <= tol ? .pass(body) : .fail(body)
}

/// 単調性の検査。`values` が（`increasing` なら）単調非減少か。
func expectMonotonic(_ values: [(label: String, value: Float)], increasing: Bool,
                     slack: Float, what: String) -> Verdict {
    var worst: (String, Float)? = nil
    for i in 1..<max(values.count, 1) {
        let d = values[i].value - values[i - 1].value
        let bad = increasing ? (d < -slack) : (d > slack)
        if bad, worst == nil || abs(d) > abs(worst!.1) {
            worst = ("\(values[i - 1].label)→\(values[i].label)", d)
        }
    }
    let table = values.map { "\($0.label)=\(f2($0.value))" }.joined(separator: " ")
    let dir = increasing ? "単調増加" : "単調減少"
    if let w = worst {
        return .fail("\(what) \(dir)でない（\(w.0) で \(f2(w.1))）| \(table)")
    }
    return .pass("\(what) \(dir) | \(table)")
}

func f0(_ v: Float) -> String { String(format: "%.0f", v) }
func f1(_ v: Float) -> String { String(format: "%.1f", v) }
func f2(_ v: Float) -> String { String(format: "%.2f", v) }
func f3(_ v: Float) -> String { String(format: "%.3f", v) }

/// 標準出力へ 1 行。
///
/// **`fflush` を外さないこと。** パイプへ流すとブロックバッファされ、
/// 「動いていない」と誤診する（0816-marionette で実際に一度誤診した）。
func emit(_ line: String) {
    print(line)
    fflush(stdout)
}

// MARK: - カメラと投影（解析側）

/// metaphor の 3D パイプラインを、公開されている式だけで組み直したもの。
///
/// 既定カメラは**毎フレーム** Processing 風に再設定される（`Canvas3D.begin`）:
///
/// ```
/// defaultZ = (height / 2) / tan(fov / 2)     // fov = π/3
/// eye      = (width / 2, height / 2, defaultZ)
/// center   = (width / 2, height / 2, 0)
/// up       = (0, 1, 0)
/// near     = defaultZ / 10,  far = defaultZ * 10
/// ```
///
/// この規約の帰結が二つあって、この作品の判定はどちらにも寄りかかっている:
///
/// - **z = 0 の平面では 1 ワールド単位 = 1 ピクセル**
/// - 深さ z での倍率は厳密に `defaultZ / (defaultZ - z)`
///
/// また `computeViewProjection` は最後に Y 反転を掛けるので、
/// **ワールドの +Y は画面の下向き**（2D と同じ）。「上」は -Y であることに注意。
struct Optics {
    let width: Float
    let height: Float
    var eye: SIMD3<Float>
    var center: SIMD3<Float>
    var up: SIMD3<Float>
    var fov: Float
    var near: Float
    var far: Float
    /// 正射影のときの範囲（left, right, bottom, top）。nil なら透視投影。
    var ortho: (left: Float, right: Float, bottom: Float, top: Float)?

    /// 既定カメラ（`camera()` も `perspective()` も呼ばなかったときの状態）。
    static func standard(width: Float, height: Float) -> Optics {
        let fov = Float.pi / 3
        let z = (height / 2) / tan(fov / 2)
        return Optics(
            width: width, height: height,
            eye: SIMD3(width / 2, height / 2, z),
            center: SIMD3(width / 2, height / 2, 0),
            up: SIMD3(0, 1, 0),
            fov: fov, near: z / 10, far: z * 10,
            ortho: nil
        )
    }

    /// 既定カメラの視距離。z = 0 平面までの距離であり、そのまま画素/単位の換算係数になる。
    static func standardZ(height: Float) -> Float {
        (height / 2) / tan((Float.pi / 3) / 2)
    }

    var defaultZ: Float { Optics.standardZ(height: height) }

    /// `ortho()` を引数なしで呼んだときの範囲（`Canvas3D+Camera.swift` の既定）。
    ///
    /// **left/right/bottom/top はワールド座標ではなくビュー空間の範囲として使われる。**
    /// 既定カメラのビュー空間は原点が画面中心なので、`[0, width] × [height, 0]` を
    /// 当てると被写体が左上へ寄る（metaphor#777 はこれ）。
    func withDefaultOrtho() -> Optics {
        var o = self
        o.ortho = (left: 0, right: width, bottom: height, top: 0)
        return o
    }

    func withOrtho(left: Float, right: Float, bottom: Float, top: Float,
                   near: Float, far: Float) -> Optics {
        var o = self
        o.ortho = (left: left, right: right, bottom: bottom, top: top)
        o.near = near
        o.far = far
        return o
    }

    func withCamera(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float> = SIMD3(0, 1, 0)) -> Optics {
        var o = self
        o.eye = eye
        o.center = center
        o.up = up
        return o
    }

    // MARK: 行列

    /// `float4x4(lookAt:center:up:)` と同じもの。
    var view: float4x4 {
        let forward = eye - center
        let z = simd_length_squared(forward) > 0 ? normalize(forward) : SIMD3<Float>(0, 0, 1)
        var xRaw = cross(up, z)
        if simd_length_squared(xRaw) < 1e-12 {
            let altUp: SIMD3<Float> = abs(z.y) < 0.99 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
            xRaw = cross(altUp, z)
        }
        let x = normalize(xRaw)
        let y = cross(z, x)
        return float4x4(columns: (
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
        ))
    }

    /// 投影行列。`ortho` が入っていれば正射影、無ければ透視投影。
    var projection: float4x4 {
        if let o = ortho {
            let sx = 2 / (o.right - o.left)
            let sy = 2 / (o.top - o.bottom)
            let sz = 1 / (near - far)
            let tx = (o.left + o.right) / (o.left - o.right)
            let ty = (o.top + o.bottom) / (o.bottom - o.top)
            let tz = near / (near - far)
            return float4x4(columns: (
                SIMD4<Float>(sx, 0, 0, 0),
                SIMD4<Float>(0, sy, 0, 0),
                SIMD4<Float>(0, 0, sz, 0),
                SIMD4<Float>(tx, ty, tz, 1)
            ))
        }
        let y = 1 / tan(fov * 0.5)
        let x = y / (width / height)
        let z = far / (near - far)
        return float4x4(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        ))
    }

    /// `computeViewProjection()` と同じ（Processing の Y 下向き規則に合わせた反転込み）。
    var viewProjection: float4x4 {
        var flipY = float4x4(1)
        flipY.columns.1.y = -1
        // Swift 5.10 は行列の 3 連鎖を型解決できないので分ける。
        let pv = projection * view
        return flipY * pv
    }

    // MARK: 投影

    /// クリップ空間の同次座標。`w <= 0` はカメラの背後（`screenPosition` はここで壊れる）。
    func clip(_ p: SIMD3<Float>) -> SIMD4<Float> {
        viewProjection * SIMD4<Float>(p.x, p.y, p.z, 1)
    }

    /// ワールド座標 → ピクセル座標（左上原点・下向きが +Y）。
    ///
    /// `screenPosition` と同じ写像。ただし**こちらは `w` も返す**ので、
    /// カメラ背後（`w <= 0`）を呼び出し側で弾ける。
    func project(_ p: SIMD3<Float>) -> (screen: SIMD2<Float>, depth: Float, w: Float) {
        let c = clip(p)
        guard c.w != 0 else { return (SIMD2(0, 0), 0, 0) }
        let ndc = SIMD3<Float>(c.x, c.y, c.z) / c.w
        return (SIMD2((ndc.x + 1) / 2 * width, (1 - ndc.y) / 2 * height), ndc.z, c.w)
    }

    /// 深さ z の平面に置いた図形の拡大率（既定カメラのとき `defaultZ / (defaultZ - z)`）。
    func foreshortening(atZ z: Float) -> Float {
        if ortho != nil { return 1 }
        let d = eye.z - center.z
        return d / (d - z)
    }
}

// MARK: - 陰影（解析側）

/// Blinn-Phong を metaphor のシェーダーと同じ式で解く。
///
/// `MetaphorLighting.h` の `calculateBlinnPhongLighting` をそのまま写したもの:
///
/// ```
/// 出力 = ambient*base + emissive + Σ (diff*NdotL + spec*pow(NdotH, shininess)) * lightColor * atten * shadow
/// ```
///
/// 押さえておくべき癖が三つある:
///
/// - **`lightCount == 0` ならシェーダーは即 `in.color` を返す。**
///   ライトを 1 つも足さなければ ambient も emissive も効かない
/// - **平行光の引数は「光の進む向き」。** シェーダー側で `L = normalize(-direction)` する
/// - **既定 ambient は 0.3。** 最初のライトを足したときに自動で入る（`ensureAmbientIfFirstLight`）
struct Shading {
    /// 既定のアンビエント比（`Canvas3D.defaultAmbientRatio`）。
    static let defaultAmbient: Float = 0.3
    /// `lights()` が仕込む平行光の進行方向と強度（`Canvas3D+Lighting.swift`）。
    static let defaultLightDirection = SIMD3<Float>(-0.5, -1.0, -0.8)
    static let defaultLightIntensity: Float = 0.7

    /// 光源 1 つぶんの寄与。
    struct Light {
        /// 光の進む向き（平行光）。`directionalLight(x, y, z)` にそのまま渡す値。
        var travel: SIMD3<Float>
        var color: SIMD3<Float> = SIMD3(1, 1, 1)
        var intensity: Float = 1
        /// 点光源なら位置。nil なら平行光。
        var position: SIMD3<Float>? = nil
        var falloff: Float = 0
    }

    var base: SIMD3<Float>
    var ambient: Float = Shading.defaultAmbient
    var emissive: SIMD3<Float> = .zero
    var specular: SIMD3<Float> = .zero
    var shininess: Float = 32

    /// 法線 `n` の点 `p` を、カメラ `eye` から見たときの色（0…1）。
    func color(at p: SIMD3<Float>, normal n: SIMD3<Float>, eye: SIMD3<Float>, lights: [Light]) -> SIMD3<Float> {
        guard !lights.isEmpty else { return base }   // シェーダーの早期 return と同じ
        let N = normalize(n)
        let V = normalize(eye - p)
        var direct = SIMD3<Float>.zero
        for l in lights {
            var L: SIMD3<Float>
            var atten: Float = 1
            if let pos = l.position {
                let vec = pos - p
                let dist = length(vec)
                L = vec / max(dist, 0.0001)
                atten = 1 / (1 + l.falloff * dist + l.falloff * 0.1 * dist * dist)
            } else {
                L = normalize(-l.travel)
            }
            let ndotl = max(dot(N, L), 0)
            let H = normalize(L + V)
            let ndoth = max(dot(N, H), 0)
            let spec = ndotl > 0 ? pow(ndoth, max(shininess, 1)) : 0
            let contribution = base * ndotl + specular * spec
            direct += contribution * l.color * l.intensity * atten
        }
        return base * ambient + emissive + direct
    }

    /// 点光源の減衰（距離 `d`・`falloff` f のとき `1 / (1 + f·d + 0.1·f·d²)`）。
    static func attenuation(distance d: Float, falloff f: Float) -> Float {
        1 / (1 + f * d + f * 0.1 * d * d)
    }
}

/// 平行光が平面 `y = planeY` に落とす、点 `p` の影の位置。
///
/// ワールドの +Y は画面下向きなので、床は「大きい y」の側にある。
/// 光が床へ向かって進んでいない（`travel.y <= 0`）なら影は落ちない。
func shadowPoint(of p: SIMD3<Float>, travel: SIMD3<Float>, planeY: Float) -> SIMD3<Float>? {
    guard travel.y > 1e-6 else { return nil }
    let t = (planeY - p.y) / travel.y
    guard t > 0 else { return nil }
    return p + travel * t
}

// MARK: - 焼き上がりを読む

/// `loadPixels()` 済みのキャンバスを読むための薄いラッパ。
///
/// `pixels` は BGRA パック済み UInt32（`(A << 24) | (R << 16) | (G << 8) | B`）で、
/// 添字は `y * width + x`。
///
/// **読み戻しは 1 フレームにつき 1 回だけ。** `loadPixels()` はレンダーパスを分割して
/// GPU の完了を待つので、採寸のたびに呼ぶと観測 → 編集 → 再観測のループが鈍る。
struct Canvas {
    let w: Int
    let h: Int
    let buf: UnsafeMutableBufferPointer<UInt32>
    /// 背景色（0…255）。これとの距離が `threshold` を超えた画素を「描かれた」とみなす。
    let ground: SIMD3<Float>
    let threshold: Float

    func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> {
        guard x >= 0, y >= 0, x < w, y < h, buf.count == w * h else { return ground }
        let p = buf[y * w + x]
        return SIMD3(Float((p >> 16) & 0xFF), Float((p >> 8) & 0xFF), Float(p & 0xFF))
    }

    /// 0…1 に正規化した色（解析側の期待値と同じ土俵に乗せる）。
    func unit(_ x: Float, _ y: Float) -> SIMD3<Float> {
        rgb(Int(x.rounded()), Int(y.rounded())) / 255
    }

    /// 小さな正方形の平均色。1 画素だけ読むとアンチエイリアスや量子化に振られるため。
    func average(around cx: Float, _ cy: Float, radius: Int = 3) -> SIMD3<Float> {
        var sum = SIMD3<Float>.zero
        var n: Float = 0
        let x0 = Int(cx.rounded()), y0 = Int(cy.rounded())
        for y in (y0 - radius)...(y0 + radius) {
            for x in (x0 - radius)...(x0 + radius) {
                guard x >= 0, y >= 0, x < w, y < h else { continue }
                sum += rgb(x, y)
                n += 1
            }
        }
        return n > 0 ? sum / n / 255 : ground / 255
    }

    /// 背景と十分に違う色が乗っているか。
    func isDrawn(_ x: Int, _ y: Int) -> Bool {
        let c = rgb(x, y)
        let d = abs(c.x - ground.x) + abs(c.y - ground.y) + abs(c.z - ground.z)
        return d > threshold
    }

    /// 矩形内で描かれた画素の外接矩形。何も無ければ nil。
    func silhouette(in rect: Rect) -> Rect? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in clampY(rect.y)..<clampY(rect.bottom) {
            for x in clampX(rect.x)..<clampX(rect.right) where isDrawn(x, y) {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard minX <= maxX else { return nil }
        return Rect(x: Float(minX), y: Float(minY),
                    w: Float(maxX - minX + 1), h: Float(maxY - minY + 1))
    }

    /// 矩形内で描かれた画素の数。
    func drawnCount(in rect: Rect) -> Int {
        var n = 0
        for y in clampY(rect.y)..<clampY(rect.bottom) {
            for x in clampX(rect.x)..<clampX(rect.right) where isDrawn(x, y) { n += 1 }
        }
        return n
    }

    /// 矩形内で、明るさが `level` を超える画素の数（ハイライトの広がりを測る）。
    func brighterCount(in rect: Rect, than level: Float) -> Int {
        var n = 0
        for y in clampY(rect.y)..<clampY(rect.bottom) {
            for x in clampX(rect.x)..<clampX(rect.right) {
                let c = rgb(x, y) / 255
                if max(c.x, max(c.y, c.z)) > level { n += 1 }
            }
        }
        return n
    }

    /// 矩形内の暗部のうち、`direction` の向きにもっとも遠い画素（影の先端を拾う）。
    ///
    /// **`brighterThan` を必ず渡すこと。** 何も描かれていない画室の暗がりは
    /// 影より暗いので、下限を置かないと画面の隅がいつでも「先端」になる
    /// （実際に一度そうなり、先端が (1279, 719) と出た）。
    func darkestExtreme(in rect: Rect, darkerThan level: Float, brighterThan floor: Float,
                        along direction: SIMD2<Float>) -> SIMD2<Float>? {
        var best: SIMD2<Float>? = nil
        var bestScore = -Float.greatestFiniteMagnitude
        let dir = normalize(direction)
        for y in clampY(rect.y)..<clampY(rect.bottom) {
            for x in clampX(rect.x)..<clampX(rect.right) {
                let v = luma(rgb(x, y) / 255)
                guard v < level, v > floor else { continue }
                let p = SIMD2(Float(x), Float(y))
                let score = dot(p, dir)
                if score > bestScore { bestScore = score; best = p }
            }
        }
        return best
    }

    private func clampX(_ v: Float) -> Int { min(max(0, Int(v)), w) }
    private func clampY(_ v: Float) -> Int { min(max(0, Int(v)), h) }
}

// MARK: - 色をそろえる

/// 期待した色（0…1）と実測色（0…1）を突き合わせる。
///
/// キャンバスは `bgra8Unorm`（sRGB 変換なし）なので、シェーダーの出力は
/// **そのまま線形に 0…255 へ載る**。ガンマを噛ませずに比べてよい。
func expectColor(_ actual: SIMD3<Float>, _ expected: SIMD3<Float>, tol: Float,
                 what: String) -> Verdict {
    let e = clampUnit(expected)
    let d = simd_max(simd_abs(actual - e), SIMD3<Float>.zero)
    let worst = max(d.x, max(d.y, d.z))
    let body = "\(what) 実測=(\(f3(actual.x)), \(f3(actual.y)), \(f3(actual.z)))"
        + " 期待=(\(f3(e.x)), \(f3(e.y)), \(f3(e.z))) 最大差=\(f3(worst)) 許容=±\(f3(tol))"
    return worst <= tol ? .pass(body) : .fail(body)
}

func clampUnit(_ v: SIMD3<Float>) -> SIMD3<Float> {
    simd_clamp(v, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
}

/// 明るさ（最大成分）。輝度の増減だけを見たいときに使う。
func luma(_ c: SIMD3<Float>) -> Float { (c.x + c.y + c.z) / 3 }
