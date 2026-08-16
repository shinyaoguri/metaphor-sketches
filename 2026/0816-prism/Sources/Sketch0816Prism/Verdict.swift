import Foundation

/// 検査 1 件の結果。
///
/// 判定を真偽値だけにしない。**実測値を含む文字列**を必ず持たせて、そのまま issue に
/// 貼れば数字が証拠になるようにする（0816-marionette / 0816-adversary / 0816-escapement
/// と同じ方針）。
struct Verdict {
    let id: String
    let passed: Bool
    let detail: String

    var line: String { "\(passed ? "PASS" : "FAIL") \(id)\t\(detail)" }
}

/// 数値の比較。Float の丸めを飲み込むための共通の物差し。
enum Approx {
    /// 絶対誤差での一致。
    static func eq(_ a: Float, _ b: Float, _ tol: Float = 1e-5) -> Bool {
        guard a.isFinite, b.isFinite else { return false }
        return abs(a - b) <= tol
    }

    static func f(_ v: Float, _ digits: Int = 4) -> String {
        v.isFinite ? String(format: "%.\(digits)f", v) : "\(v)"
    }
}

// MARK: - 色の物差し

/// 色の比較と表示。
///
/// **ピクセルを読み戻す検査の許容差は数式の検査より緩くていい。** 8bit テクスチャを
/// 経由すると 1/255 ≒ 0.0039 の量子化が必ず乗るし、sRGB のパイプラインを通ると
/// さらに丸めが乗る。ここを 1e-5 で締めると量子化を「不一致」と誤報する。
enum Hue {
    /// 数式どうしの比較に使う許容差。
    static let exact: Float = 1e-4
    /// 8bit テクスチャを往復した色に使う許容差（量子化 1/255 の 2 倍強）。
    static let quantized: Float = 0.01

    /// RGB 3 成分の一致（アルファは見ない）。
    static func rgbEq(_ a: (Float, Float, Float), _ b: (Float, Float, Float), _ tol: Float) -> Bool {
        Approx.eq(a.0, b.0, tol) && Approx.eq(a.1, b.1, tol) && Approx.eq(a.2, b.2, tol)
    }

    static func s(_ c: (Float, Float, Float)) -> String {
        "(\(Approx.f(c.0, 3)), \(Approx.f(c.1, 3)), \(Approx.f(c.2, 3)))"
    }

    static func s(_ c: (Float, Float, Float, Float)) -> String {
        "(\(Approx.f(c.0, 3)), \(Approx.f(c.1, 3)), \(Approx.f(c.2, 3)), a=\(Approx.f(c.3, 3)))"
    }

    /// 標準の HSV → RGB 変換。**metaphor の実装は見ずに、教科書の式から独立に書き下す。**
    ///
    /// 実装をなぞって書くと「実装と実装を比べる」トートロジーになり、変換が間違っていても
    /// PASS してしまう。ここが層 A のオラクルなので、由来は外部の定義でなければならない。
    /// h / s / v はいずれも 0…1 正規化。
    static func hsvToRGB(_ h: Float, _ s: Float, _ v: Float) -> (Float, Float, Float) {
        if s <= 0 { return (v, v, v) }
        var hh = h.truncatingRemainder(dividingBy: 1)
        if hh < 0 { hh += 1 }
        let h6 = hh * 6
        let i = Int(h6.rounded(.down)) % 6
        let f = h6 - h6.rounded(.down)
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
