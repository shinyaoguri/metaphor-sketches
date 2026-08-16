import Foundation

/// 検査 1 件の結果。
///
/// 判定を真偽値だけにしない。**実測値を含む文字列**を必ず持たせて、そのまま issue に
/// 貼れば数字が証拠になるようにする（0816-marionette / 0816-adversary / 0816-escapement と同じ方針）。
struct Verdict {
    let id: String
    let passed: Bool
    let detail: String

    var line: String { "\(passed ? "PASS" : "FAIL") \(id)\t\(detail)" }
}

/// 8bit の RGBA。読み戻した実測も、式から出した期待値もこの型で扱う。
struct RGBA8: Equatable {
    var r: Int
    var g: Int
    var b: Int
    var a: Int

    init(_ r: Int, _ g: Int, _ b: Int, _ a: Int = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// 0…1 の実数から。丸めは四捨五入。
    init(unit r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
        func q(_ v: Float) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        self.init(q(r), q(g), q(b), q(a))
    }

    /// チャンネルごとの最大差。アルファは含めない（読み戻し先が不透明なことが多いため）。
    func rgbDistance(to o: RGBA8) -> Int {
        max(abs(r - o.r), max(abs(g - o.g), abs(b - o.b)))
    }

    /// RGB が許容差の内側か。
    func rgbNear(_ o: RGBA8, tol: Int = 2) -> Bool { rgbDistance(to: o) <= tol }

    var rgbText: String { "rgb(\(r),\(g),\(b))" }
    var text: String { "rgba(\(r),\(g),\(b),\(a))" }
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

/// 実測と期待を並べた 1 行を組み立てる。issue へそのまま貼れる形にする。
func compare(_ what: String, _ got: RGBA8, _ want: RGBA8, tol: Int) -> (Bool, String) {
    let ok = got.rgbNear(want, tol: tol)
    let d = got.rgbDistance(to: want)
    return (ok, "\(what) 実測=\(got.rgbText) 期待=\(want.rgbText) 差=\(d) 許容=\(tol)")
}
