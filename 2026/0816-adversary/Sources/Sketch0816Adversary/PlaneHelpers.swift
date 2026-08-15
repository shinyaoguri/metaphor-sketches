import metaphor

// 検査セルの中で繰り返し使う描画・判定の道具。

/// よく使う識別しやすい色 (互いに十分離れていること = ink 判定と誤認しない)。
enum Ink {
    static let red = (r: 240, g: 60, b: 60)
    static let blue = (r: 60, g: 120, b: 240)
    static let green = (r: 60, g: 220, b: 120)
    static let amber = (r: 230, g: 150, b: 40)
    static let violet = (r: 170, g: 90, b: 230)
    static let white = (r: 235, g: 240, b: 245)
}

extension Sketch0816Adversary {

    /// セルを「実測 (左)」と「期待の見本 (右)」に割る。
    /// 判定は実測側だけを読み、見本は目視で並べて比べるために描く。
    func split(_ r: Rect) -> (subject: Rect, reference: Rect) {
        let subjectW = r.w * 0.60
        let refW = r.w * 0.32
        return (
            Rect(x: r.x, y: r.y, w: subjectW, h: r.h),
            Rect(x: r.right - refW, y: r.y, w: refW, h: r.h)
        )
    }

    /// 期待の見本として色の帯を描く。
    func swatch(_ r: Rect, _ c: (r: Int, g: Int, b: Int)) {
        noStroke()
        fill(Float(c.r), Float(c.g), Float(c.b))
        rectMode(.corner)
        rect(r.cx - 22, r.cy - 22, 44, 44)
    }
}

// MARK: - 判定ヘルパ

/// 指定座標の色が期待どおりか。
func expectColor(
    _ px: PixelReader, at x: Float, _ y: Float,
    _ want: (r: Int, g: Int, b: Int), tol: Int = 32, what: String
) -> Verdict {
    let got = px.rgb(x, y)
    let d = abs(got.r - want.r) + abs(got.g - want.g) + abs(got.b - want.b)
    let gotS = "rgb(\(got.r),\(got.g),\(got.b))"
    let wantS = "rgb(\(want.r),\(want.g),\(want.b))"
    if d <= tol * 3 {
        return .pass("\(what)=\(gotS)")
    }
    return .fail("\(what)=\(gotS) 期待 \(wantS)")
}

/// 描かれた範囲 (ink の外接矩形) が期待どおりか。
func expectBounds(
    _ got: Rect?, _ want: Rect, tol: Float = 3, what: String
) -> Verdict {
    guard let got else {
        return .fail("\(what): 何も描かれていない 期待 \(fmt(want))")
    }
    let dx = abs(got.x - want.x), dy = abs(got.y - want.y)
    let dw = abs(got.w - want.w), dh = abs(got.h - want.h)
    if dx <= tol && dy <= tol && dw <= tol && dh <= tol {
        return .pass("\(what)=\(fmt(got))")
    }
    return .fail("\(what)=\(fmt(got)) 期待 \(fmt(want))")
}

/// 数値が期待どおりか。
func expectValue(
    _ got: Float, _ want: Float, tol: Float, what: String, unit: String = ""
) -> Verdict {
    if abs(got - want) <= tol {
        return .pass("\(what)=\(r1(got))\(unit)")
    }
    return .fail("\(what)=\(r1(got))\(unit) 期待 \(r1(want))\(unit)")
}

/// 2 つのプロファイルの相関 (-1…1)。長さが違うときは短い方に合わせて線形に読み直す。
func profileCorrelation(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count >= 3, b.count >= 3 else { return 0 }
    let n = min(a.count, b.count)
    func resample(_ v: [Float]) -> [Float] {
        (0..<n).map { i in
            let t = Float(i) * Float(v.count - 1) / Float(n - 1)
            let i0 = Int(t), i1 = min(i0 + 1, v.count - 1)
            let f = t - Float(i0)
            return v[i0] * (1 - f) + v[i1] * f
        }
    }
    let x = resample(a), y = resample(b)
    let mx = x.reduce(0, +) / Float(n), my = y.reduce(0, +) / Float(n)
    var num: Float = 0, dx: Float = 0, dy: Float = 0
    for i in 0..<n {
        let a0 = x[i] - mx, b0 = y[i] - my
        num += a0 * b0
        dx += a0 * a0
        dy += b0 * b0
    }
    let den = (dx * dy).squareRoot()
    return den > 0 ? num / den : 0
}

/// 矩形を短く文字列化する (セル 1 行に収める)。
func fmt(_ r: Rect) -> String {
    "(\(r0(r.x)),\(r0(r.y)) \(r0(r.w))×\(r0(r.h)))"
}

func r0(_ v: Float) -> String { String(Int(v.rounded())) }

func r1(_ v: Float) -> String {
    let s = (v * 10).rounded() / 10
    return s == s.rounded() ? String(Int(s)) : String(format: "%.1f", s)
}
