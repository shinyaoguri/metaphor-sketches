import Foundation
import metaphor
import simd

// 決定論的な検査群。
//
// 描画も実時計も使わないので、実行するたびに同じ数値が出る。`setup()` で 1 回だけ回し、
// 結果を frame.json の `custom`（`check.<ID>`）と標準出力へ出す。
//
// この作品が狙うのは **もっとも基本的な層** — 数の関数・イージング・波形・乱数・定数・
// 状態の往復。オラクルはすべて閉じた数式なので、ピクセルを読まずに判定できる。
// 時間・ループ制御・入力（T / L / I 系）はフレームを跨がないと測れないので `Runtime.swift`。

@MainActor
enum Instrument {
    static func runAll() -> [Verdict] {
        var out: [Verdict] = []
        out += math()
        out += easing()
        out += waveforms()
        out += randomness()
        out += constants()
        return out
    }

    // MARK: - M 系: 数の関数

    static func math() -> [Verdict] {
        var out: [Verdict] = []

        // M1: map は線形写像か。順方向・逆方向（stop < start）の両方を当てる。
        do {
            let a = map(5, 0, 10, 0, 100)          // 期待 50
            let b = map(2.5, 0, 10, 100, 0)        // 期待 75（出力レンジが逆）
            let c = map(-5, -10, 10, 0, 1)         // 期待 0.25（入力に負を含む）
            let ok = Approx.eq(a, 50) && Approx.eq(b, 75) && Approx.eq(c, 0.25)
            out.append(Verdict(id: "M1.map", passed: ok,
                detail: "map(5,0,10,0,100)=\(Approx.f(a)) 期待=50.0000 / 逆レンジ=\(Approx.f(b)) 期待=75.0000 / 負域=\(Approx.f(c)) 期待=0.2500"))
        }

        // M2: 入力レンジの外を渡したとき外挿するか（Processing は clamp せず外挿する）。
        do {
            let over = map(15, 0, 10, 0, 100)      // 外挿なら 150
            let under = map(-5, 0, 10, 0, 100)     // 外挿なら -50
            let ok = Approx.eq(over, 150) && Approx.eq(under, -50)
            out.append(Verdict(id: "M2.mapExtrapolate", passed: ok,
                detail: "map(15)=\(Approx.f(over)) 期待=150.0000 / map(-5)=\(Approx.f(under)) 期待=-50.0000（Processing は clamp しない）"))
        }

        // M3: 退化した入力レンジ（start1 == stop1）。0 除算になる。
        //     doc は何も言っていないので「NaN / Inf を返さない」ことだけを要求する。
        do {
            let v = map(5, 3, 3, 0, 100)
            let ok = v.isFinite
            out.append(Verdict(id: "M3.mapDegenerate", passed: ok,
                detail: "map(5,3,3,0,100)=\(Approx.f(v))（有限値であること。NaN/Inf は呼び出し側へ伝播して絵を壊す）"))
        }

        // M4: lerp。t の内側・端・外側。
        do {
            let mid = lerp(Float(0), Float(10), Float(0.5))
            let lo = lerp(Float(0), Float(10), Float(0))
            let hi = lerp(Float(0), Float(10), Float(1))
            let out2 = lerp(Float(0), Float(10), Float(2))   // 外挿なら 20
            let ok = Approx.eq(mid, 5) && Approx.eq(lo, 0) && Approx.eq(hi, 10) && Approx.eq(out2, 20)
            out.append(Verdict(id: "M4.lerp", passed: ok,
                detail: "t=0.5→\(Approx.f(mid)) t=0→\(Approx.f(lo)) t=1→\(Approx.f(hi)) t=2→\(Approx.f(out2)) 期待=5/0/10/20"))
        }

        // M5: ベクタ版 lerp がスカラ版と成分ごとに一致するか。
        do {
            let v2 = lerp(SIMD2<Float>(0, 0), SIMD2<Float>(10, 20), 0.25)
            let v3 = lerp(SIMD3<Float>(1, 2, 3), SIMD3<Float>(3, 6, 9), 0.5)
            let v4 = lerp(SIMD4<Float>(0, 0, 0, 0), SIMD4<Float>(4, 8, 12, 16), 0.75)
            let ok = Approx.eq(v2.x, 2.5) && Approx.eq(v2.y, 5)
                && Approx.eq(v3.x, 2) && Approx.eq(v3.y, 4) && Approx.eq(v3.z, 6)
                && Approx.eq(v4.w, 12)
            out.append(Verdict(id: "M5.lerpVector", passed: ok,
                detail: "v2=(\(Approx.f(v2.x)),\(Approx.f(v2.y))) 期待=(2.5,5) / v3.y=\(Approx.f(v3.y)) 期待=4 / v4.w=\(Approx.f(v4.w)) 期待=12"))
        }

        // M6: constrain の上下クランプ。
        do {
            let inside = constrain(5, 0, 10)
            let below = constrain(-1, 0, 10)
            let above = constrain(11, 0, 10)
            let ok = Approx.eq(inside, 5) && Approx.eq(below, 0) && Approx.eq(above, 10)
            out.append(Verdict(id: "M6.constrain", passed: ok,
                detail: "5→\(Approx.f(inside)) -1→\(Approx.f(below)) 11→\(Approx.f(above)) 期待=5/0/10"))
        }

        // M7: low > high の逆転。doc に記述が無いので、落ちない・NaN を出さないことを要求する。
        do {
            let v = constrain(5, 10, 0)
            let ok = v.isFinite
            out.append(Verdict(id: "M7.constrainReversed", passed: ok,
                detail: "constrain(5,10,0)=\(Approx.f(v))（doc に規定なし。実測を記録する）"))
        }

        // M8: norm は map(v, s, e, 0, 1) と同値か。
        do {
            let n = norm(5, 0, 10)
            let m = map(5, 0, 10, 0, 1)
            let deg = norm(3, 3, 3)
            let ok = Approx.eq(n, 0.5) && Approx.eq(n, m) && deg.isFinite
            out.append(Verdict(id: "M8.norm", passed: ok,
                detail: "norm=\(Approx.f(n)) map 同値=\(Approx.f(m)) 期待=0.5000 / 退化 norm(3,3,3)=\(Approx.f(deg))"))
        }

        // M9: mag と dist。3-4-5 と 1-2-2 の直角三角形で当てる。
        do {
            let m2 = mag(3, 4)
            let m3 = mag(1, 2, 2)
            let d2 = dist(1, 1, 4, 5)
            let d3 = dist(0, 0, 0, 1, 2, 2)
            let ok = Approx.eq(m2, 5) && Approx.eq(m3, 3) && Approx.eq(d2, 5) && Approx.eq(d3, 3)
            out.append(Verdict(id: "M9.magDist", passed: ok,
                detail: "mag2=\(Approx.f(m2)) mag3=\(Approx.f(m3)) dist2=\(Approx.f(d2)) dist3=\(Approx.f(d3)) 期待=5/3/5/3"))
        }

        // M10: sq は負値でも正になるか。
        do {
            let a = sq(-3)
            let b = sq(0)
            let ok = Approx.eq(a, 9) && Approx.eq(b, 0)
            out.append(Verdict(id: "M10.sq", passed: ok,
                detail: "sq(-3)=\(Approx.f(a)) 期待=9.0000 / sq(0)=\(Approx.f(b))"))
        }

        // M11: 角度の変換。往復して元に戻るか。
        do {
            let r = radians(180)
            let d = degrees(Float.pi)
            let round = degrees(radians(37))
            let ok = Approx.eq(r, .pi) && Approx.eq(d, 180, 1e-3) && Approx.eq(round, 37, 1e-3)
            out.append(Verdict(id: "M11.angle", passed: ok,
                detail: "radians(180)=\(Approx.f(r, 6)) 期待=\(Approx.f(Float.pi, 6)) / degrees(PI)=\(Approx.f(d)) 期待=180 / 往復 37→\(Approx.f(round))"))
        }

        // M12: saturate は constrain(x, 0, 1) と同値か。
        do {
            var same = true
            var worst: (Float, Float, Float) = (0, 0, 0)
            for i in -20...30 {
                let x = Float(i) / 10
                let a = saturate(x), b = constrain(x, 0, 1)
                if !Approx.eq(a, b) { same = false; worst = (x, a, b) }
            }
            out.append(Verdict(id: "M12.saturate", passed: same,
                detail: same ? "x∈[-2,3] の 51 点すべてで constrain(x,0,1) と一致"
                             : "x=\(Approx.f(worst.0)) で saturate=\(Approx.f(worst.1)) constrain=\(Approx.f(worst.2))"))
        }

        // M13: smoothstep は 3t²-2t³ か（区間外はクランプされるか）。
        do {
            let quarter = smoothstep(0, 1, 0.25)   // 3(0.0625) - 2(0.015625) = 0.15625
            let half = smoothstep(0, 1, 0.5)       // 0.5
            let below = smoothstep(0, 1, -1)       // 0
            let above = smoothstep(0, 1, 2)        // 1
            let shifted = smoothstep(10, 20, 12.5) // 正規化して 0.25 → 0.15625
            let ok = Approx.eq(quarter, 0.15625) && Approx.eq(half, 0.5)
                && Approx.eq(below, 0) && Approx.eq(above, 1) && Approx.eq(shifted, 0.15625)
            out.append(Verdict(id: "M13.smoothstep", passed: ok,
                detail: "t=0.25→\(Approx.f(quarter, 6)) 期待=0.156250 / t=0.5→\(Approx.f(half)) / 区間外 -1→\(Approx.f(below)) 2→\(Approx.f(above)) / 平行移動→\(Approx.f(shifted, 6))"))
        }

        // M14: edge0 == edge1 の退化。0 除算。
        do {
            let v = smoothstep(1, 1, 2)
            let ok = v.isFinite
            out.append(Verdict(id: "M14.smoothstepDegenerate", passed: ok,
                detail: "smoothstep(1,1,2)=\(Approx.f(v))（有限値であること）"))
        }

        // M15: 3 次ベジェ。端点と、接線が数値微分と一致するか。
        do {
            let (a, b, c, d): (Float, Float, Float, Float) = (0, 10, 20, 30)
            let p0 = bezierPoint(a, b, c, d, 0)
            let p1 = bezierPoint(a, b, c, d, 1)
            // 制御点が等間隔なら曲線は直線になり、t=0.5 は中点
            let pm = bezierPoint(a, b, c, d, 0.5)
            // 接線 = 微分。h=1e-3 の中心差分と比べる
            let h: Float = 1e-3
            let numeric = (bezierPoint(a, b, c, d, 0.5 + h) - bezierPoint(a, b, c, d, 0.5 - h)) / (2 * h)
            let tangent = bezierTangent(a, b, c, d, 0.5)
            let ok = Approx.eq(p0, 0) && Approx.eq(p1, 30) && Approx.eq(pm, 15, 1e-3)
                && Approx.rel(tangent, numeric, 1e-2)
            out.append(Verdict(id: "M15.bezier", passed: ok,
                detail: "t=0→\(Approx.f(p0)) t=1→\(Approx.f(p1)) 期待=0/30 / t=0.5→\(Approx.f(pm)) 期待=15 / 接線=\(Approx.f(tangent)) 数値微分=\(Approx.f(numeric))"))
        }

        // M16: Catmull-Rom。t=0 で b、t=1 で c を通るのが定義。
        do {
            let (a, b, c, d): (Float, Float, Float, Float) = (0, 10, 20, 30)
            let p0 = curvePoint(a, b, c, d, 0)
            let p1 = curvePoint(a, b, c, d, 1)
            let h: Float = 1e-3
            let numeric = (curvePoint(a, b, c, d, 0.5 + h) - curvePoint(a, b, c, d, 0.5 - h)) / (2 * h)
            let tangent = curveTangent(a, b, c, d, 0.5)
            let ok = Approx.eq(p0, 10, 1e-3) && Approx.eq(p1, 20, 1e-3)
                && Approx.rel(tangent, numeric, 1e-2)
            out.append(Verdict(id: "M16.curve", passed: ok,
                detail: "t=0→\(Approx.f(p0)) 期待=10（第 2 制御点） t=1→\(Approx.f(p1)) 期待=20 / 接線=\(Approx.f(tangent)) 数値微分=\(Approx.f(numeric))"))
        }

        return out
    }

    // MARK: - E 系: イージング 30 本

    /// (族名, In, Out, InOut)。標準的な定義なら 3 つは互いに導出できる関係にある。
    static let easingFamilies: [(String, (Float) -> Float, (Float) -> Float, (Float) -> Float)] = [
        ("Sine", easeInSine, easeOutSine, easeInOutSine),
        ("Quad", easeInQuad, easeOutQuad, easeInOutQuad),
        ("Cubic", easeInCubic, easeOutCubic, easeInOutCubic),
        ("Quart", easeInQuart, easeOutQuart, easeInOutQuart),
        ("Quint", easeInQuint, easeOutQuint, easeInOutQuint),
        ("Expo", easeInExpo, easeOutExpo, easeInOutExpo),
        ("Circ", easeInCirc, easeOutCirc, easeInOutCirc),
        ("Back", easeInBack, easeOutBack, easeInOutBack),
        ("Elastic", easeInElastic, easeOutElastic, easeInOutElastic),
        ("Bounce", easeInBounce, easeOutBounce, easeInOutBounce),
    ]

    /// オーバーシュートしない（値域が [0,1] に収まるはずの）族。
    static let monotoneFamilies = ["Sine", "Quad", "Cubic", "Quart", "Quint", "Expo", "Circ"]

    static func easing() -> [Verdict] {
        var out: [Verdict] = []

        // E1: 全 30 本が f(0)=0 / f(1)=1 を満たすか。イージングの最低条件。
        do {
            var bad: [String] = []
            for (name, fin, fout, finout) in easingFamilies {
                for (suffix, f) in [("In", fin), ("Out", fout), ("InOut", finout)] {
                    let a = f(0), b = f(1)
                    if !Approx.eq(a, 0, 1e-4) || !Approx.eq(b, 1, 1e-4) {
                        bad.append("ease\(suffix)\(name) f(0)=\(Approx.f(a)) f(1)=\(Approx.f(b))")
                    }
                }
            }
            out.append(Verdict(id: "E1.endpoints", passed: bad.isEmpty,
                detail: bad.isEmpty ? "30 本すべて f(0)=0 / f(1)=1"
                                    : "\(bad.count) 本が外れた: \(bad.prefix(4).joined(separator: " / "))"))
        }

        // E2: In ↔ Out の鏡像。標準定義なら easeOut(t) == 1 - easeIn(1-t) が全 t で成り立つ。
        do {
            var bad: [String] = []
            for (name, fin, fout, _) in easingFamilies {
                var worst: Float = 0
                var at: Float = 0
                for i in 0...100 {
                    let t = Float(i) / 100
                    let diff = abs(fout(t) - (1 - fin(1 - t)))
                    if diff > worst { worst = diff; at = t }
                }
                if worst > 1e-4 { bad.append("\(name) 最大差=\(Approx.f(worst, 6)) at t=\(Approx.f(at, 2))") }
            }
            out.append(Verdict(id: "E2.inOutMirror", passed: bad.isEmpty,
                detail: bad.isEmpty ? "10 族すべてで easeOut(t) == 1 - easeIn(1-t)（101 点、最大差 < 1e-4）"
                                    : bad.joined(separator: " / ")))
        }

        // E3: InOut の点対称。f(t) + f(1-t) == 1。
        do {
            var bad: [String] = []
            for (name, _, _, finout) in easingFamilies {
                var worst: Float = 0
                var at: Float = 0
                for i in 0...100 {
                    let t = Float(i) / 100
                    let diff = abs(finout(t) + finout(1 - t) - 1)
                    if diff > worst { worst = diff; at = t }
                }
                if worst > 1e-4 { bad.append("\(name) 最大差=\(Approx.f(worst, 6)) at t=\(Approx.f(at, 2))") }
            }
            out.append(Verdict(id: "E3.inOutSymmetry", passed: bad.isEmpty,
                detail: bad.isEmpty ? "10 族すべてで f(t) + f(1-t) == 1（101 点、最大差 < 1e-4）"
                                    : bad.joined(separator: " / ")))
        }

        // E4: 単調族が本当に単調非減少か（1000 分割）。
        do {
            var bad: [String] = []
            for (name, fin, fout, finout) in easingFamilies where monotoneFamilies.contains(name) {
                for (suffix, f) in [("In", fin), ("Out", fout), ("InOut", finout)] {
                    var prev = f(0)
                    var drop: Float = 0
                    for i in 1...1000 {
                        let v = f(Float(i) / 1000)
                        drop = min(drop, v - prev)
                        prev = v
                    }
                    if drop < -1e-5 { bad.append("ease\(suffix)\(name) 最大の逆行=\(Approx.f(drop, 6))") }
                }
            }
            out.append(Verdict(id: "E4.monotonic", passed: bad.isEmpty,
                detail: bad.isEmpty ? "Sine/Quad/Cubic/Quart/Quint/Expo/Circ の 21 本が単調非減少（1000 分割）"
                                    : bad.joined(separator: " / ")))
        }

        // E5: 単調族が [0,1] を出ないか。Back / Elastic は逆に出るのが正しい。
        do {
            var bad: [String] = []
            for (name, fin, fout, finout) in easingFamilies where monotoneFamilies.contains(name) {
                for (suffix, f) in [("In", fin), ("Out", fout), ("InOut", finout)] {
                    var lo: Float = 0, hi: Float = 1
                    for i in 0...1000 {
                        let v = f(Float(i) / 1000)
                        lo = min(lo, v); hi = max(hi, v)
                    }
                    if lo < -1e-4 || hi > 1 + 1e-4 {
                        bad.append("ease\(suffix)\(name) 値域=[\(Approx.f(lo)),\(Approx.f(hi))]")
                    }
                }
            }
            out.append(Verdict(id: "E5.monotoneRange", passed: bad.isEmpty,
                detail: bad.isEmpty ? "単調族 21 本が [0,1] に収まる" : bad.joined(separator: " / ")))
        }

        // E6: Back / Elastic は定義上オーバーシュートする。しないなら実装が別物。
        do {
            var report: [String] = []
            var ok = true
            for (name, fin, fout, _) in easingFamilies where name == "Back" || name == "Elastic" {
                var lo: Float = 0, hi: Float = 1
                for i in 0...1000 {
                    let t = Float(i) / 1000
                    lo = min(lo, fin(t), fout(t)); hi = max(hi, fin(t), fout(t))
                }
                let overshoots = hi > 1.01 && lo < -0.01
                ok = ok && overshoots
                report.append("\(name) 値域=[\(Approx.f(lo)),\(Approx.f(hi))]")
            }
            out.append(Verdict(id: "E6.overshoot", passed: ok,
                detail: "\(report.joined(separator: " / "))（両端とも [0,1] を出るのが定義どおり）"))
        }

        // E7: Bounce が区間の継ぎ目で飛ばないか。連続なら 1/1000 刻みの跳びは小さい。
        do {
            var worst: Float = 0
            var at: Float = 0
            var prev = easeOutBounce(0)
            for i in 1...1000 {
                let t = Float(i) / 1000
                let v = easeOutBounce(t)
                if abs(v - prev) > worst { worst = abs(v - prev); at = t }
                prev = v
            }
            // 1/1000 刻みで 0.05 を超える跳びがあれば継ぎ目が壊れている
            let ok = worst < 0.05
            out.append(Verdict(id: "E7.bounceContinuity", passed: ok,
                detail: "easeOutBounce の隣接差分 最大=\(Approx.f(worst, 6)) at t=\(Approx.f(at, 3))（閾値 0.05）"))
        }

        // E8: ease(t, from:to:using:) は a + (b-a)·f(t) か。
        do {
            var worst: Float = 0
            for i in 0...100 {
                let t = Float(i) / 100
                let got = ease(t, from: 10, to: 30, using: easeInOutCubic)
                let want = 10 + 20 * easeInOutCubic(t)
                worst = max(worst, abs(got - want))
            }
            let outside = ease(1.5, from: 0, to: 10, using: easeInOutCubic)
            let ok = worst < 1e-4 && outside.isFinite
            out.append(Verdict(id: "E8.ease", passed: ok,
                detail: "101 点の最大差=\(Approx.f(worst, 6))（期待 a+(b-a)·f(t)）/ t=1.5 の外挿=\(Approx.f(outside))"))
        }

        return out
    }

    // MARK: - W 系: 波形

    static let waves: [(String, (Double) -> Float)] = [
        ("sine01", { sine01($0, frequency: 1) }),
        ("cosine01", { cosine01($0, frequency: 1) }),
        ("triangle", { triangle($0, frequency: 1) }),
        ("sawtooth", { sawtooth($0, frequency: 1) }),
        ("square", { square($0, frequency: 1, duty: 0.5) }),
    ]

    static func waveforms() -> [Verdict] {
        var out: [Verdict] = []

        // W1: 全波形が [0,1] に収まるか。doc がそう言っている。
        do {
            var bad: [String] = []
            for (name, f) in waves {
                var lo: Float = 1, hi: Float = 0
                for i in 0..<2000 {
                    let v = f(Double(i) / 500)     // 4 周期ぶん
                    lo = min(lo, v); hi = max(hi, v)
                }
                if lo < -1e-4 || hi > 1 + 1e-4 { bad.append("\(name)=[\(Approx.f(lo)),\(Approx.f(hi))]") }
            }
            out.append(Verdict(id: "W1.range", passed: bad.isEmpty,
                detail: bad.isEmpty ? "5 波形すべてが 4 周期 2000 点で [0,1] に収まる" : bad.joined(separator: " / ")))
        }

        // W2: 周期が 1/frequency か。t と t+1 で一致するはず（frequency=1）。
        do {
            var bad: [String] = []
            for (name, f) in waves {
                var worst: Float = 0
                for i in 0..<200 {
                    let t = Double(i) / 200
                    worst = max(worst, abs(f(t) - f(t + 1)))
                }
                if worst > 1e-4 { bad.append("\(name) 最大差=\(Approx.f(worst, 6))") }
            }
            out.append(Verdict(id: "W2.period", passed: bad.isEmpty,
                detail: bad.isEmpty ? "5 波形すべてで f(t) == f(t+1)（frequency=1、200 点）" : bad.joined(separator: " / ")))
        }

        // W3: frequency を 2 倍にすると周期が半分か。f(t, 2) == f(2t, 1) を要求する。
        do {
            var bad: [String] = []
            let doubled: [(String, (Double) -> Float, (Double) -> Float)] = [
                ("sine01", { sine01($0, frequency: 2) }, { sine01($0 * 2, frequency: 1) }),
                ("cosine01", { cosine01($0, frequency: 2) }, { cosine01($0 * 2, frequency: 1) }),
                ("triangle", { triangle($0, frequency: 2) }, { triangle($0 * 2, frequency: 1) }),
                ("sawtooth", { sawtooth($0, frequency: 2) }, { sawtooth($0 * 2, frequency: 1) }),
                ("square", { square($0, frequency: 2, duty: 0.5) }, { square($0 * 2, frequency: 1, duty: 0.5) }),
            ]
            for (name, fast, scaled) in doubled {
                var worst: Float = 0
                for i in 0..<200 {
                    let t = Double(i) / 200
                    worst = max(worst, abs(fast(t) - scaled(t)))
                }
                if worst > 1e-4 { bad.append("\(name) 最大差=\(Approx.f(worst, 6))") }
            }
            out.append(Verdict(id: "W3.frequency", passed: bad.isEmpty,
                detail: bad.isEmpty ? "5 波形すべてで f(t, 2Hz) == f(2t, 1Hz)" : bad.joined(separator: " / ")))
        }

        // W4: cosine01 は sine01 の 1/4 周期ぶん先か（cos x = sin(x + π/2)）。
        do {
            var worst: Float = 0
            var at: Double = 0
            for i in 0..<400 {
                let t = Double(i) / 400
                let diff = abs(cosine01(t, frequency: 1) - sine01(t + 0.25, frequency: 1))
                if diff > worst { worst = diff; at = t }
            }
            let ok = worst < 1e-4
            out.append(Verdict(id: "W4.sineCosinePhase", passed: ok,
                detail: "cosine01(t) vs sine01(t+0.25) 最大差=\(Approx.f(worst, 6)) at t=\(Approx.f(at, 3))"))
        }

        // W5: square は 0 か 1 だけを出し、1 の占める割合が duty と一致するか。
        do {
            var report: [String] = []
            var ok = true
            for duty in [0.25, 0.5, 0.75] {
                var high = 0
                var onlyBinary = true
                let n = 100_000
                for i in 0..<n {
                    let v = square(Double(i) / Double(n), frequency: 1, duty: duty)
                    if v > 0.5 { high += 1 }
                    if !(Approx.eq(v, 0) || Approx.eq(v, 1)) { onlyBinary = false }
                }
                let ratio = Double(high) / Double(n)
                let good = onlyBinary && abs(ratio - duty) < 0.01
                ok = ok && good
                report.append("duty=\(duty)→実比 \(Approx.f(ratio, 4))\(onlyBinary ? "" : " ※0/1 以外あり")")
            }
            out.append(Verdict(id: "W5.squareDuty", passed: ok, detail: report.joined(separator: " / ")))
        }

        // W6: duty の退化（0 と 1）。常に 0 / 常に 1 になるのが素直な期待。
        do {
            var zeroAlwaysLow = true, oneAlwaysHigh = true
            for i in 0..<1000 {
                let t = Double(i) / 1000
                if square(t, frequency: 1, duty: 0) > 0.5 { zeroAlwaysLow = false }
                if square(t, frequency: 1, duty: 1) < 0.5 { oneAlwaysHigh = false }
            }
            let ok = zeroAlwaysLow && oneAlwaysHigh
            out.append(Verdict(id: "W6.squareDutyDegenerate", passed: ok,
                detail: "duty=0 は常に 0 → \(zeroAlwaysLow) / duty=1 は常に 1 → \(oneAlwaysHigh)"))
        }

        // W7: sawtooth は 1 周期の中で単調増加し、周期端で 1 → 0 に落ちるか。
        //     周期の内側（0.001〜0.999）だけを見るので、落ち込みは現れないはず。
        do {
            var maxDrop: Float = 0
            var prev = sawtooth(0.001, frequency: 1)
            for i in 2..<1000 {
                let v = sawtooth(Double(i) / 1000, frequency: 1)
                if v < prev { maxDrop = max(maxDrop, prev - v) }
                prev = v
            }
            let span = sawtooth(0.999, frequency: 1) - sawtooth(0.001, frequency: 1)
            let ok = maxDrop < 0.01 && span > 0.9
            out.append(Verdict(id: "W7.sawtooth", passed: ok,
                detail: "周期内の最大の逆行=\(Approx.f(maxDrop, 6))（期待 ~0）/ 0.001→0.999 の伸び=\(Approx.f(span))（期待 ~1）"))
        }

        // W8: triangle が区分線形で、半周期に頂点を持つか。
        //     形が想定と違ったときに読み解けるよう、4 点の実測を detail に残す。
        do {
            let s = [0.0, 0.25, 0.5, 0.75].map { triangle($0, frequency: 1) }
            // 前半（頂点の手前まで）で 2 階差分が ~0 = 直線であること
            var worstCurv: Float = 0
            for i in 1..<249 {
                let t = Double(i) / 500
                let c = triangle(t - 0.002, frequency: 1) - 2 * triangle(t, frequency: 1) + triangle(t + 0.002, frequency: 1)
                worstCurv = max(worstCurv, abs(c))
            }
            let ok = Approx.eq(s[0], 0, 1e-3) && Approx.eq(s[1], 0.5, 1e-3)
                && Approx.eq(s[2], 1, 1e-3) && Approx.eq(s[3], 0.5, 1e-3) && worstCurv < 1e-3
            out.append(Verdict(id: "W8.triangle", passed: ok,
                detail: "t=0/0.25/0.5/0.75 → \(s.map { Approx.f($0) }.joined(separator: "/")) 期待=0.0000/0.5000/1.0000/0.5000 / 前半の 2 階差分 最大=\(Approx.f(worstCurv, 6))（直線なら ~0）"))
        }

        return out
    }

    // MARK: - R 系: 乱数とノイズ

    static func randomness() -> [Verdict] {
        var out: [Verdict] = []

        // R1: randomSeed で列が再現するか。作品の梨地が毎回同じ絵になる根拠。
        do {
            randomSeed(20260816)
            let a = (0..<64).map { _ in random(1) }
            randomSeed(20260816)
            let b = (0..<64).map { _ in random(1) }
            randomSeed(20260817)
            let c = (0..<64).map { _ in random(1) }
            let same = zip(a, b).allSatisfy { Approx.eq($0, $1, 0) }
            let differs = zip(a, c).contains { !Approx.eq($0, $1, 0) }
            out.append(Verdict(id: "R1.randomSeed", passed: same && differs,
                detail: "同一シードで 64 個一致=\(same) / 別シードで相違=\(differs) / 先頭=\(Approx.f(a[0], 6))"))
        }

        // R2: random(high) が [0, high) を守るか（上限は排他のはず）。
        do {
            randomSeed(1)
            var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
            for _ in 0..<200_000 { let v = random(10); lo = min(lo, v); hi = max(hi, v) }
            let ok = lo >= 0 && hi < 10
            out.append(Verdict(id: "R2.randomHigh", passed: ok,
                detail: "20 万サンプルの範囲=[\(Approx.f(lo, 6)),\(Approx.f(hi, 6))] 期待=[0,10)"))
        }

        // R3: random(low, high) と、low > high の逆転。
        do {
            randomSeed(2)
            var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
            for _ in 0..<200_000 { let v = random(-5, 5); lo = min(lo, v); hi = max(hi, v) }
            randomSeed(3)
            var rlo = Float.greatestFiniteMagnitude, rhi = -Float.greatestFiniteMagnitude
            var finite = true
            for _ in 0..<10_000 {
                let v = random(5, -5)
                if !v.isFinite { finite = false }
                rlo = min(rlo, v); rhi = max(rhi, v)
            }
            let ok = lo >= -5 && hi < 5 && finite
            out.append(Verdict(id: "R3.randomRange", passed: ok,
                detail: "[-5,5) の実測=[\(Approx.f(lo, 6)),\(Approx.f(hi, 6))] / 逆転 random(5,-5) の実測=[\(Approx.f(rlo, 6)),\(Approx.f(rhi, 6))] 有限=\(finite)"))
        }

        // R4: 一様性。10 分割のヒストグラムで、どのビンも期待から 3% 以上ずれないこと。
        do {
            randomSeed(4)
            let n = 200_000
            var bins = [Int](repeating: 0, count: 10)
            for _ in 0..<n {
                let idx = min(9, Int(random(1) * 10))
                bins[idx] += 1
            }
            let expected = Double(n) / 10
            let worst = bins.map { abs(Double($0) - expected) / expected }.max() ?? 0
            let ok = worst < 0.03
            out.append(Verdict(id: "R4.uniformity", passed: ok,
                detail: "20 万サンプル・10 ビンの最大偏差=\(Approx.f(worst * 100, 2))%（閾値 3%）"))
        }

        // R5: randomGaussian の平均・標準偏差。
        do {
            randomSeed(5)
            let n = 200_000
            var sum = 0.0, sumSq = 0.0
            for _ in 0..<n {
                let v = Double(randomGaussian(5, 2))
                sum += v; sumSq += v * v
            }
            let mean = sum / Double(n)
            let sd = (sumSq / Double(n) - mean * mean).squareRoot()
            let ok = abs(mean - 5) < 0.05 && abs(sd - 2) < 0.05
            out.append(Verdict(id: "R5.randomGaussian", passed: ok,
                detail: "20 万サンプル 平均=\(Approx.f(mean, 4)) 期待=5 / 標準偏差=\(Approx.f(sd, 4)) 期待=2"))
        }

        // R6: noiseSeed で再現するか。
        do {
            noiseSeed(777)
            let a = (0..<64).map { noise(Float($0) * 0.13, Float($0) * 0.07) }
            noiseSeed(777)
            let b = (0..<64).map { noise(Float($0) * 0.13, Float($0) * 0.07) }
            noiseSeed(778)
            let c = (0..<64).map { noise(Float($0) * 0.13, Float($0) * 0.07) }
            let same = zip(a, b).allSatisfy { Approx.eq($0, $1, 0) }
            let differs = zip(a, c).contains { !Approx.eq($0, $1, 1e-6) }
            out.append(Verdict(id: "R6.noiseSeed", passed: same && differs,
                detail: "同一シードで 64 点一致=\(same) / 別シードで相違=\(differs) / 先頭=\(Approx.f(a[0], 6))"))
        }

        // R7: noise の値域。Processing の noise() は [0,1]。
        do {
            noiseSeed(11)
            noiseDetail(octaves: 4, falloff: 0.5)
            var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
            for i in 0..<40_000 {
                let x = Float(i) * 0.013
                let v = noise(x, x * 0.7, x * 0.31)
                lo = min(lo, v); hi = max(hi, v)
            }
            let ok = lo >= -1e-4 && hi <= 1 + 1e-4
            out.append(Verdict(id: "R7.noiseRange", passed: ok,
                detail: "4 万点の 3D noise 範囲=[\(Approx.f(lo, 6)),\(Approx.f(hi, 6))] 期待=[0,1]"))
        }

        // R8: noise の連続性。近い座標なら値も近いのが Perlin の定義。
        do {
            noiseSeed(12)
            noiseDetail(octaves: 1, falloff: 0.5)
            var worst: Float = 0
            var prev = noise(0)
            for i in 1..<20_000 {
                let v = noise(Float(i) * 0.001)
                worst = max(worst, abs(v - prev))
                prev = v
            }
            // 0.001 刻みで 0.05 を超える跳びがあれば連続とは言えない
            let ok = worst < 0.05
            out.append(Verdict(id: "R8.noiseContinuity", passed: ok,
                detail: "1D noise の 0.001 刻み隣接差分 最大=\(Approx.f(worst, 6))（閾値 0.05）"))
        }

        // R9: noiseDetail のオクターブが、fBm の理論どおりに効くか。
        //
        // 「オクターブを増やせば粗くなる」は**間違った期待**だった（最初この検査は誤報を出した）。
        // 振幅は maxAmplitude で正規化されるので、falloff=0.5 のとき各オクターブの
        // 微分寄与は等しく、N オクターブの微分 RMS は
        //     R(N) ∝ √N / (1 - 2^-N)
        // に比例する。N=1 で正規化すると r(N) = 0.5·√N / (1 - 2^-N) で、
        //     r(1)=1.000  r(2)=0.943  r(4)=1.067  r(8)=1.420
        // つまり **1 → 2 では逆にわずかに滑らかになる**のが正しい。
        //
        // 刻み幅にも注意が要る。8 オクターブ目は周波数 128（波長 ≈0.0078）なので、
        // 刻みを 0.01 にすると折り返して理論とずれる。0.0005 で取る。
        do {
            func roughness(octaves: Int) -> Double {
                noiseSeed(13)
                noiseDetail(octaves: octaves, falloff: 0.5)
                let step: Float = 0.0005
                let n = 20_000
                var sum = 0.0
                var prev = noise(0)
                for i in 1..<n {
                    let v = noise(Float(i) * step)
                    sum += Double(v - prev) * Double(v - prev)
                    prev = v
                }
                return (sum / Double(n)).squareRoot()
            }
            func theory(_ n: Int) -> Double {
                0.5 * Double(n).squareRoot() / (1 - pow(2, -Double(n)))
            }
            let counts = [1, 2, 4, 8]
            let series = counts.map { roughness(octaves: $0) }
            let base = series[0]
            let measured = series.map { $0 / base }
            let expected = counts.map(theory)
            let worst = zip(measured, expected).map { abs($0 - $1) / $1 }.max() ?? 1
            let ok = worst < 0.10
            out.append(Verdict(id: "R9.noiseDetail", passed: ok,
                detail: "微分 RMS の比（N=1 を 1 とする）: "
                    + zip(counts, zip(measured, expected)).map { "oct\($0)=\(Approx.f($1.0, 3))(理論 \(Approx.f($1.1, 3)))" }.joined(separator: " ")
                    + " / 最大相対誤差=\(Approx.f(worst * 100, 2))%（閾値 10%。理論は √N/(1-2^-N)）"))
            // 作品が使う設定へ戻す
            noiseDetail(octaves: 4, falloff: 0.5)
        }

        // R10: falloff（オクターブごとの減衰）が効くか。
        //      小さい falloff ほど高オクターブの寄与が減り、なめらかになるはず。
        do {
            func roughness(falloff: Float) -> Double {
                noiseSeed(14)
                noiseDetail(octaves: 6, falloff: falloff)
                var sum = 0.0
                var prev = noise(0)
                for i in 1..<20_000 {
                    let v = noise(Float(i) * 0.01)
                    sum += Double(v - prev) * Double(v - prev)
                    prev = v
                }
                return (sum / 20_000).squareRoot()
            }
            let falloffs: [Float] = [0.2, 0.5, 0.8]
            let series = falloffs.map { roughness(falloff: $0) }
            let monotone = zip(series, series.dropFirst()).allSatisfy { $1 > $0 }
            out.append(Verdict(id: "R10.noiseFalloff", passed: monotone,
                detail: "隣接差分 RMS: " + zip(falloffs, series).map { "falloff\(Approx.f($0, 1))=\(Approx.f($1, 6))" }.joined(separator: " ")
                    + " / 単調増加=\(monotone)（falloff を上げたら粗くなるのが期待）"))
            noiseDetail(octaves: 4, falloff: 0.5)
        }

        return out
    }

    // MARK: - C 系: 定数

    /// macOS の仮想キーコード（Carbon HIToolbox の `kVK_*`）。外部真値としてここに書き下す。
    static let virtualKeyCodes: [(String, UInt16, UInt16)] = [
        ("LEFT", LEFT, 123),
        ("RIGHT", RIGHT, 124),
        ("DOWN", DOWN, 125),
        ("UP", UP, 126),
        ("SPACE", SPACE, 49),
        ("TAB", TAB, 48),
        ("ESCAPE", ESCAPE, 53),
        ("RETURN", RETURN, 36),
        ("ENTER", ENTER, 76),          // テンキーの Enter
        ("BACKSPACE", BACKSPACE, 51),  // 手前削除（macOS の Delete キー）
        ("DELETE", DELETE, 117),       // 前方削除（Fn+Delete）
        ("SHIFT", SHIFT, 56),
        ("CONTROL", CONTROL, 59),
        ("OPTION", OPTION, 58),
        ("ALT", ALT, 58),
        ("COMMAND", COMMAND, 55),
    ]

    static func constants() -> [Verdict] {
        var out: [Verdict] = []

        // C1: 円周率まわりの厳密値と、定数どうしの関係。
        do {
            let ok = Approx.eq(PI, .pi, 1e-7)
                && Approx.eq(TAU, 2 * .pi, 1e-6)
                && Approx.eq(TWO_PI, TAU, 0)
                && Approx.eq(HALF_PI, .pi / 2, 1e-7)
                && Approx.eq(QUARTER_PI, .pi / 4, 1e-7)
            out.append(Verdict(id: "C1.pi", passed: ok,
                detail: "PI=\(Approx.f(PI, 7)) TAU=\(Approx.f(TAU, 7)) TWO_PI=\(Approx.f(TWO_PI, 7)) HALF_PI=\(Approx.f(HALF_PI, 7)) QUARTER_PI=\(Approx.f(QUARTER_PI, 7)) / TAU==TWO_PI=\(TAU == TWO_PI)"))
        }

        // C2: キーコード定数が macOS の仮想キーコードと一致するか。
        do {
            let bad = virtualKeyCodes.filter { $0.1 != $0.2 }
            out.append(Verdict(id: "C2.keyCodes", passed: bad.isEmpty,
                detail: bad.isEmpty ? "16 個すべて kVK_* と一致（LEFT=123 RIGHT=124 DOWN=125 UP=126 SPACE=49 TAB=48 ESCAPE=53 RETURN=36 ENTER=76 …）"
                                    : bad.map { "\($0.0)=\($0.1) 期待=\($0.2)" }.joined(separator: " / ")))
        }

        // C3: doc が言っている別名・別物の関係。
        do {
            // `RETURN` は Darwin の同名マクロ（sys/tty.h の `#define RETURN 6`）と衝突する。
            // 型注釈で候補を 1 つに絞らないと「ambiguous use of 'RETURN'」で通らない
            // （`metaphor.RETURN` と書いても駄目 — metaphor は Foundation を再エクスポート
            //  しているので、モジュール修飾では絞り込めない）。詳しくは 0816-probe-constants
            let ret: UInt16 = RETURN
            let aliasOK = ALT == OPTION
            let distinctOK = ret != ENTER
            out.append(Verdict(id: "C3.keyAliases", passed: aliasOK && distinctOK,
                detail: "ALT(\(ALT)) == OPTION(\(OPTION)) → \(aliasOK)（doc は別名と言う）/ RETURN(\(ret)) != ENTER(\(ENTER)) → \(distinctOK)（doc は本体 Return とテンキー Enter で別物と言う）"))
        }

        return out
    }
}
