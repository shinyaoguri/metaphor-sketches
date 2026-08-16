import Foundation

/// 検査 1 件の結果。
///
/// 判定を真偽値だけにしない。**実測値を含む文字列**を必ず持たせて、そのまま issue に
/// 貼れば数字が証拠になるようにする（0816-marionette / 0816-adversary / 0816-escapement /
/// 0816-prism と同じ方針）。
struct Verdict {
    let id: String
    let passed: Bool
    let detail: String

    var line: String { "\(passed ? "PASS" : "FAIL") \(id)\t\(detail)" }
}

/// 判定でも FAIL でもない、「見て決めるしかない」もの。
///
/// この作品には**仕様が書かれていない**ものが混ざる（`MergePass` の α 前提、
/// `Graphics3D` の初期クリア色）。期待値が無いものを PASS / FAIL に押し込むと、
/// 実装をなぞっただけの検査になる。実測だけを残して判断は人間へ返す。
struct Observation {
    let id: String
    let detail: String

    var line: String { "LOOK \(id)\t\(detail)" }
}

/// 数値の比較。Float の丸めを飲み込むための共通の物差し。
enum Approx {
    static func eq(_ a: Float, _ b: Float, _ tol: Float = 1e-5) -> Bool {
        guard a.isFinite, b.isFinite else { return false }
        return abs(a - b) <= tol
    }

    static func f(_ v: Float, _ digits: Int = 4) -> String {
        v.isFinite ? String(format: "%.\(digits)f", v) : "\(v)"
    }
}

// MARK: - 色の物差し

/// 色の比較と表示。0816-prism の `Hue` を踏襲する。
///
/// **ピクセルを読み戻す検査の許容差は数式の検査より緩くていい。** 8bit テクスチャを
/// 経由すると 1/255 ≒ 0.0039 の量子化が必ず乗る。ここを 1e-5 で締めると量子化を
/// 「不一致」と誤報する。
///
/// この作品はさらに**合成を挟む**ので、量子化が 2 回以上乗る経路がある
/// （層を焼く → 8bit → マージ → 8bit → 読み戻し）。その分だけ広い許容差も用意する。
enum Hue {
    /// 数式どうしの比較に使う許容差。
    static let exact: Float = 1e-4
    /// 8bit テクスチャを 1 往復した色（層を直接読む）。
    static let quantized: Float = 0.01
    /// 8bit を 2 段以上経由した色（層 → マージ → 読み戻し）。
    static let composited: Float = 0.02

    static func rgbEq(_ a: (Float, Float, Float), _ b: (Float, Float, Float), _ tol: Float) -> Bool {
        Approx.eq(a.0, b.0, tol) && Approx.eq(a.1, b.1, tol) && Approx.eq(a.2, b.2, tol)
    }

    static func s(_ c: (Float, Float, Float)) -> String {
        "(\(Approx.f(c.0, 3)), \(Approx.f(c.1, 3)), \(Approx.f(c.2, 3)))"
    }

    static func s(_ c: (Float, Float, Float, Float)) -> String {
        "(\(Approx.f(c.0, 3)), \(Approx.f(c.1, 3)), \(Approx.f(c.2, 3)), a=\(Approx.f(c.3, 3)))"
    }

    /// 差の最大成分。「どれだけずれたか」を 1 つの数で言うために使う。
    static func maxDelta(_ a: (Float, Float, Float), _ b: (Float, Float, Float)) -> Float {
        max(abs(a.0 - b.0), max(abs(a.1 - b.1), abs(a.2 - b.2)))
    }
}

// MARK: - 合成のオラクル

/// `MergePass.BlendType` の doc が名乗る式を、**doc の文面だけから**書き下したもの。
///
/// 実装（`MetaphorMerge.metal`）を読んで写すとトートロジーになる。ここは
/// 公開 doc に書かれている次の 4 行だけを根拠にする:
///
/// - `add`      … Additive blending (A + B)
/// - `alpha`    … Alpha compositing (B over A)
/// - `multiply` … Multiply blending (A * B)
/// - `screen`   … Screen blending (1 - (1-A) * (1-B))
///
/// `alpha` だけは「B over A」という**名前**しか無く、B のカラーが乗算済み
/// （premultiplied）か否かが書かれていない。両方の解釈を返して、実測がどちらに
/// 寄るかを見る（`M5`）。
enum MergeOracle {
    /// A + B。出力が 8bit 正規化テクスチャなので、書き込み時に [0,1] へ丸められる。
    static func add(_ a: (Float, Float, Float), _ b: (Float, Float, Float)) -> (Float, Float, Float) {
        (min(1, a.0 + b.0), min(1, a.1 + b.1), min(1, a.2 + b.2))
    }

    static func multiply(_ a: (Float, Float, Float), _ b: (Float, Float, Float)) -> (Float, Float, Float) {
        (a.0 * b.0, a.1 * b.1, a.2 * b.2)
    }

    static func screen(_ a: (Float, Float, Float), _ b: (Float, Float, Float)) -> (Float, Float, Float) {
        (1 - (1 - a.0) * (1 - b.0), 1 - (1 - a.1) * (1 - b.1), 1 - (1 - a.2) * (1 - b.2))
    }

    /// B over A、B のカラーが**まだ α を掛けられていない**（straight alpha）前提。
    ///   result = B.rgb * B.a + A.rgb * (1 - B.a)
    static func alphaStraight(
        _ a: (Float, Float, Float), _ b: (Float, Float, Float), _ bAlpha: Float
    ) -> (Float, Float, Float) {
        (b.0 * bAlpha + a.0 * (1 - bAlpha),
         b.1 * bAlpha + a.1 * (1 - bAlpha),
         b.2 * bAlpha + a.2 * (1 - bAlpha))
    }

    /// B over A、B のカラーが**既に α を掛けられている**（premultiplied）前提。
    ///   result = B.rgb + A.rgb * (1 - B.a)
    static func alphaPremultiplied(
        _ a: (Float, Float, Float), _ b: (Float, Float, Float), _ bAlpha: Float
    ) -> (Float, Float, Float) {
        (b.0 + a.0 * (1 - bAlpha),
         b.1 + a.1 * (1 - bAlpha),
         b.2 + a.2 * (1 - bAlpha))
    }
}
