import Foundation

/// 検査 1 件の結果。
///
/// 判定を真偽値だけにしない。**実測値を含む文字列**を必ず持たせて、そのまま issue に
/// 貼れば数字が証拠になるようにする（0816-marionette / 0816-adversary と同じ方針）。
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

    /// 相対誤差での一致（大きい値どうしの比較に使う）。
    static func rel(_ a: Float, _ b: Float, _ tol: Float = 1e-4) -> Bool {
        guard a.isFinite, b.isFinite else { return false }
        let scale = max(abs(a), abs(b), 1)
        return abs(a - b) / scale <= tol
    }

    static func f(_ v: Float, _ digits: Int = 4) -> String {
        v.isFinite ? String(format: "%.\(digits)f", v) : "\(v)"
    }

    static func f(_ v: Double, _ digits: Int = 4) -> String {
        v.isFinite ? String(format: "%.\(digits)f", v) : "\(v)"
    }
}
