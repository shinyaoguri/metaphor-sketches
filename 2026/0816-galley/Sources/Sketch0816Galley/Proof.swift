import metaphor

// 校正の道具立て。
//
// 紙面に刷った墨だけを読み戻し、期待とずれた箇所へ朱を入れるための型をここに置く。
// 読み戻しは 1 ページにつき 1 回だけ (loadPixels() はレンダーパスを分割して GPU の
// 完了を待つので、要素ごとに呼ぶと観測 → 編集 → 再観測のループが鈍る)。
//
// 刷る順番が判定の前提になっている:
//   1. 紙 (background) → 2. 墨 (本文・見本) → 3. ★ここで読み戻す★ → 4. 罫と朱と欄外
// 罫 (青) と朱 (赤) を先に引くと ink 判定に混ざるので、必ず判定より後に描く。

/// 紙面上の矩形。左上原点・ピクセル単位で、キャンバス座標と `pixels` の添字が一致する前提。
struct Rect {
    var x: Float
    var y: Float
    var w: Float
    var h: Float

    var right: Float { x + w }
    var bottom: Float { y + h }
    var cx: Float { x + w / 2 }
    var cy: Float { y + h / 2 }
}

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
    /// 「直ったか」を判定する (recheck.py は `now == "PASS"` を見ている)。
    var token: String {
        switch self {
        case .pass: return "PASS"
        case .fail: return "FAIL"
        case .look: return "LOOK"
        }
    }

    /// 紙面の欄外に出す語。校正刷りの言い方に寄せる (機械が読むのは `token` のほう)。
    var mark: String {
        switch self {
        case .pass: return "OK"
        case .fail: return "直し"
        case .look: return "要確認"
        }
    }

    var detail: String {
        switch self {
        case .pass(let s), .fail(let s), .look(let s): return s
        }
    }

    /// probe と標準出力へ出す 1 行。実測値を必ず含める。
    var line: String { "\(token) \(detail)" }
}

/// 朱の入れ方。校正刷りの記号を、計量のずれを指すために使う。
enum ProofMark {
    /// 「ここに来るはず」と「実際に来た」を、水平方向の差として指す。
    case shiftX(expected: Float, actual: Float, y: Float)
    /// 同じく垂直方向。
    case shiftY(expected: Float, actual: Float, x: Float)
    /// 範囲そのものを囲う (欠け・はみ出し)。
    case ring(Rect)
}

/// 1 件の照合。`id` はそのまま `probe("check.<id>", …)` のキーになる。
struct Finding {
    let id: String
    /// 欄外に出す短い題。
    let title: String
    let verdict: Verdict
    /// 朱を入れる位置 (紙面座標)。不要なら nil。
    var mark: ProofMark?

    init(_ id: String, _ title: String, _ verdict: Verdict, mark: ProofMark? = nil) {
        self.id = id
        self.title = title
        self.verdict = verdict
        self.mark = mark
    }
}

/// `loadPixels()` 済みの紙面を読むための薄いラッパ。
///
/// `pixels` は BGRA パック済み UInt32 (`(A << 24) | (R << 16) | (G << 8) | B`) で、
/// 添字は `y * width + x`。
struct PixelReader {
    let w: Int
    let h: Int
    let buf: UnsafeMutableBufferPointer<UInt32>
    /// 紙の色。これとの距離が `inkThreshold` を超えた画素を「刷られた」とみなす。
    let paper: (r: Int, g: Int, b: Int)
    let inkThreshold: Int

    func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        guard x >= 0, y >= 0, x < w, y < h, buf.count == w * h else { return paper }
        let p = buf[y * w + x]
        return (Int((p >> 16) & 0xFF), Int((p >> 8) & 0xFF), Int(p & 0xFF))
    }

    /// 紙と十分に違う色が乗っているか。
    func isInk(_ x: Int, _ y: Int) -> Bool {
        let c = rgb(x, y)
        return abs(c.r - paper.r) + abs(c.g - paper.g) + abs(c.b - paper.b) > inkThreshold
    }

    /// 矩形内で刷られた画素の外接矩形。何も無ければ nil。
    func inkBounds(in rect: Rect) -> Rect? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in clampY(rect.y)..<clampY(rect.bottom) {
            for x in clampX(rect.x)..<clampX(rect.right) where isInk(x, y) {
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

    /// 矩形内で刷られた画素の数。
    func inkCount(in rect: Rect) -> Int {
        var n = 0
        for y in clampY(rect.y)..<clampY(rect.bottom) {
            for x in clampX(rect.x)..<clampX(rect.right) where isInk(x, y) { n += 1 }
        }
        return n
    }

    private func clampX(_ v: Float) -> Int { min(max(0, Int(v)), w) }
    private func clampY(_ v: Float) -> Int { min(max(0, Int(v)), h) }
}

// MARK: - 判定のヘルパ

/// 実測と期待を突き合わせ、差を必ず数値で残す。
func expect(_ actual: Float, _ expected: Float, tol: Float,
            what: String, unit: String = "px") -> Verdict {
    let d = actual - expected
    let body = "\(what) 実測=\(f1(actual))\(unit) 期待=\(f1(expected))\(unit) 差=\(f1(d))\(unit)"
    return abs(d) <= tol ? .pass(body) : .fail("\(body) 許容=\(f1(tol))\(unit)")
}

func f1(_ v: Float) -> String { String(format: "%.1f", v) }
func f2(_ v: Float) -> String { String(format: "%.2f", v) }
func f0(_ v: Float) -> String { String(format: "%.0f", v) }

/// 標準出力へ 1 行。パイプへ流すとブロックバッファされるので必ず流し切る
/// (ここを怠ると「動いていない」と誤診する)。
func emit(_ line: String) {
    print(line)
    fflush(stdout)
}
