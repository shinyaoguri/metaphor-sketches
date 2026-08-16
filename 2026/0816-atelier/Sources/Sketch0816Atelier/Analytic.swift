import Foundation
import simd

// 「その形が画面のどこを占めるはずか」を、metaphor を呼ばずに出す係。
//
// 三角形分割の中身までは真似しない。真似すると metaphor の内部実装を写経することになり、
// 実装が変わった瞬間に検査が壊れるうえ、**同じ間違いを二度書けば PASS になってしまう**。
//
// 代わりに、どの分割でも成り立つ**両側の境界**で挟む:
//
// - 凸なプリミティブのメッシュは球や円に**内接する**ので、実測は理想値を超えない
// - 分割数 N の内接多角形は、外接円の `cos(π/N)` 倍までは必ず届く
//
// つまり `理想 × cos(π/N) ≦ 実測 ≦ 理想`。この幅は detail=40 なら 0.3% ほどで、
// 「寸法が指定どおりか」を判定するには十分に狭い。

extension Optics {

    /// 点群の投影後の外接矩形。**カメラ背後（w ≦ 0）の点は捨てる。**
    ///
    /// `screenPosition` は `clip.z / clip.w` をそのまま返すので `w < 0` で符号が反転する。
    /// 0816-marionette ではこれを踏んで自分の検査バグを 8 件出した（#10）。
    /// ここでは `w` を見られるようにしてあるので、同じ穴には落ちない。
    func bounds(of points: [SIMD3<Float>]) -> Rect? {
        var minX = Float.greatestFiniteMagnitude, minY = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        var any = false
        for p in points {
            let r = project(p)
            guard r.w > 0 else { continue }
            any = true
            minX = min(minX, r.screen.x); maxX = max(maxX, r.screen.x)
            minY = min(minY, r.screen.y); maxY = max(maxY, r.screen.y)
        }
        guard any else { return nil }
        return Rect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }

    /// 中心 `c`・半径 `r` の球が画面に落とす見かけの半径。
    ///
    /// 透視投影では球のシルエットは接線円錐で決まるので、単純な `r × 倍率` ではない。
    /// 視点から中心までの距離を d とすると `見かけ半径 = f · r / √(d² − r²)`
    /// （f は z=0 平面での画素/単位＝`defaultZ`）。
    func apparentSphereRadius(center c: SIMD3<Float>, radius r: Float) -> Float {
        if ortho != nil { return r }
        let d = length(eye - c)
        guard d > r else { return .greatestFiniteMagnitude }
        return (eye.z - center.z) * r / sqrt(d * d - r * r)
    }
}

// MARK: - プリミティブの標本点

/// 各プリミティブの「輪郭を決める点」を吐く。細かく刻んだ理想形なので、
/// 実測はこれ以下・`cos(π/detail)` 倍以上に収まるはず。
enum Sample {
    /// 円周を `n` 分割した点（平面は `axisA`, `axisB` が張る）。
    static func circle(center: SIMD3<Float>, radius: Float,
                       axisA: SIMD3<Float>, axisB: SIMD3<Float>, n: Int = 720) -> [SIMD3<Float>] {
        (0..<n).map { i in
            let a = Float(i) / Float(n) * Float.pi * 2
            return center + axisA * (cos(a) * radius) + axisB * (sin(a) * radius)
        }
    }

    /// 球の表面を細かく刻んだ点。
    ///
    /// 投影後の外接矩形を取るために使う。立体の投影は**その立体の全点の投影の和**なので、
    /// 十分に細かく刻めば外接矩形は真のシルエットに一致する。
    /// 画面の軸から外れた球は接線円錐が斜めに切れて楕円になり、
    /// 「半径×倍率」では出せない（軸上の閉じた式は `apparentSphereRadius`）。
    static func spherePoints(center c: SIMD3<Float>, radius r: Float,
                             lat: Int = 96, lon: Int = 192) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(lat * lon)
        for i in 0...lat {
            let theta = Float(i) / Float(lat) * Float.pi
            let st = sin(theta), ct = cos(theta)
            for j in 0..<lon {
                let phi = Float(j) / Float(lon) * Float.pi * 2
                out.append(c + SIMD3(r * st * cos(phi), r * ct, r * st * sin(phi)))
            }
        }
        return out
    }

    /// 立方体・直方体の 8 隅。分割に依らないので**理想と実測が一致するはず**。
    static func boxCorners(center c: SIMD3<Float>, size s: SIMD3<Float>) -> [SIMD3<Float>] {
        let h = s / 2
        var out: [SIMD3<Float>] = []
        for sx in [-1, 1] as [Float] {
            for sy in [-1, 1] as [Float] {
                for sz in [-1, 1] as [Float] {
                    out.append(c + SIMD3(h.x * sx, h.y * sy, h.z * sz))
                }
            }
        }
        return out
    }

    /// 平面（XY・法線 +Z）の 4 隅。
    static func planeCorners(center c: SIMD3<Float>, width w: Float, height h: Float) -> [SIMD3<Float>] {
        [
            c + SIMD3(-w / 2, -h / 2, 0), c + SIMD3(w / 2, -h / 2, 0),
            c + SIMD3(w / 2, h / 2, 0), c + SIMD3(-w / 2, h / 2, 0),
        ]
    }

    /// 円柱（軸 = Y、高さ h が ±h/2）の上下の縁。
    static func cylinderRims(center c: SIMD3<Float>, radius r: Float, height h: Float) -> [SIMD3<Float>] {
        let x = SIMD3<Float>(1, 0, 0), z = SIMD3<Float>(0, 0, 1)
        return circle(center: c + SIMD3(0, -h / 2, 0), radius: r, axisA: x, axisB: z)
            + circle(center: c + SIMD3(0, h / 2, 0), radius: r, axisA: x, axisB: z)
    }

    /// 円錐（軸 = Y、頂点が +Y、底面が -Y）の頂点と底の縁。
    ///
    /// **頂点が +Y ということは、ワールドの Y が下向きなので画面では下を向く。**
    /// 立てて見せたければ呼ぶ側が反転しなければならない。
    static func conePoints(center c: SIMD3<Float>, radius r: Float, height h: Float) -> [SIMD3<Float>] {
        let x = SIMD3<Float>(1, 0, 0), z = SIMD3<Float>(0, 0, 1)
        return [c + SIMD3(0, h / 2, 0)]
            + circle(center: c + SIMD3(0, -h / 2, 0), radius: r, axisA: x, axisB: z)
    }

    /// トーラス（リング面 = XZ、管が ±tube だけ Y に張り出す）の管表面。
    static func torusPoints(center c: SIMD3<Float>, ring R: Float, tube t: Float,
                            uN: Int = 360, vN: Int = 48) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(uN * vN)
        for i in 0..<uN {
            let u = Float(i) / Float(uN) * Float.pi * 2
            let cu = cos(u), su = sin(u)
            for j in 0..<vN {
                let v = Float(j) / Float(vN) * Float.pi * 2
                let rr = R + t * cos(v)
                out.append(c + SIMD3(rr * cu, t * sin(v), rr * su))
            }
        }
        return out
    }
}

/// 「理想値以下・`cos(π/detail)` 倍以上」に収まっているかを判定する。
///
/// 実測が理想を**超える**のは、分割が外接している（＝指定より大きく描いている）か、
/// 寸法の解釈が違うということなので、上側も見る。
func expectInscribed(_ actual: Float, ideal: Float, detail: Int,
                     slack: Float = 2.5, what: String) -> Verdict {
    let lo = ideal * cos(Float.pi / Float(max(detail, 3))) - slack
    let hi = ideal + slack
    let body = "\(what) 実測=\(f2(actual))px 理想=\(f2(ideal))px"
        + " 許容=[\(f2(lo)), \(f2(hi))]px（内接多角形の欠けと滲みの ±\(f2(slack))px を見込む）"
    return (actual >= lo && actual <= hi) ? .pass(body) : .fail(body)
}
