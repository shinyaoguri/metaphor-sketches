import metaphor

// 検査盤の骨格。
//
// 1 つの検査 (Check) は「セルの中に描く」「描いた結果のピクセルを読んで期待と照合する」の
// 2 つで完結する。描画と判定を同じフレームで行うため、判定は必ず全セルを描き終えたあと
// loadPixels() を **1 回だけ** 呼んで、その 1 枚から全セル分を読む
// (loadPixels はレンダーパスを分割して GPU 完了を待つので、セルごとに呼ぶと重い)。

/// 検査盤上の矩形。左上原点・ピクセル単位で、キャンバス座標と `pixels` の添字が一致する前提。
struct Rect {
    var x: Float
    var y: Float
    var w: Float
    var h: Float

    var right: Float { x + w }
    var bottom: Float { y + h }
    var cx: Float { x + w / 2 }
    var cy: Float { y + h / 2 }

    func inset(_ dx: Float, _ dy: Float) -> Rect {
        Rect(x: x + dx, y: y + dy, w: w - dx * 2, h: h - dy * 2)
    }
}

/// 1 検査の判定結果。
enum Verdict {
    /// 期待どおり。付随する文字列は実測の要約。
    case pass(String)
    /// 期待に反した。文字列は「実測 → 期待」を人が読める形で。
    case fail(String)
    /// 自動判定に落とせず、目視に回すもの。
    case visual(String)

    var isFail: Bool { if case .fail = self { return true }; return false }
    var isPass: Bool { if case .pass = self { return true }; return false }

    var label: String {
        switch self {
        case .pass(let s): return "PASS \(s)"
        case .fail(let s): return "FAIL \(s)"
        case .visual(let s): return "LOOK \(s)"
        }
    }

    var detail: String {
        switch self {
        case .pass(let s), .fail(let s), .visual(let s): return s
        }
    }
}

/// `loadPixels()` 済みのキャンバスを読むための薄いラッパ。
///
/// `pixels` は BGRA パック済み UInt32 (`(A << 24) | (R << 16) | (G << 8) | B`) で、
/// 添字は `y * width + x`。
struct PixelReader {
    let w: Int
    let h: Int
    let buf: UnsafeMutableBufferPointer<UInt32>
    /// 背景色。これとの距離が `inkThreshold` を超えた画素を「描かれた」とみなす。
    let bg: (r: Int, g: Int, b: Int)
    let inkThreshold: Int

    func packed(_ x: Int, _ y: Int) -> UInt32 {
        guard x >= 0, y >= 0, x < w, y < h, buf.count == w * h else { return 0 }
        return buf[y * w + x]
    }

    func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let p = packed(x, y)
        return (Int((p >> 16) & 0xFF), Int((p >> 8) & 0xFF), Int(p & 0xFF))
    }

    func rgb(_ x: Float, _ y: Float) -> (r: Int, g: Int, b: Int) {
        rgb(Int(x.rounded()), Int(y.rounded()))
    }

    /// 背景と十分に違う色が乗っているか。
    func isInk(_ x: Int, _ y: Int) -> Bool {
        let c = rgb(x, y)
        let d = abs(c.r - bg.r) + abs(c.g - bg.g) + abs(c.b - bg.b)
        return d > inkThreshold
    }

    /// 指定色に十分近いか (チャンネルごとの許容差)。
    func isNear(_ x: Float, _ y: Float, _ r: Int, _ g: Int, _ b: Int, tol: Int = 24) -> Bool {
        let c = rgb(x, y)
        return abs(c.r - r) <= tol && abs(c.g - g) <= tol && abs(c.b - b) <= tol
    }

    /// 矩形内で描かれた画素の数。
    func inkCount(in rect: Rect) -> Int {
        var n = 0
        for y in Int(rect.y)..<Int(rect.bottom) {
            for x in Int(rect.x)..<Int(rect.right) where isInk(x, y) {
                n += 1
            }
        }
        return n
    }

    /// 矩形内で描かれた画素の割合 (0…1)。
    func coverage(in rect: Rect) -> Float {
        let total = max(1, Int(rect.w) * Int(rect.h))
        return Float(inkCount(in: rect)) / Float(total)
    }

    /// 矩形内で描かれた画素の外接矩形。何も描かれていなければ nil。
    func inkBounds(in rect: Rect) -> Rect? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in Int(rect.y)..<Int(rect.bottom) {
            for x in Int(rect.x)..<Int(rect.right) where isInk(x, y) {
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

    /// 矩形内の各行の ink 画素数。ink のある範囲だけに詰めて返す
    /// (2 か所に描いた同じ図形を、垂直位置の差を無視して形として比べるため)。
    func inkRowProfile(in rect: Rect) -> [Float] {
        var rows: [Float] = []
        for y in Int(rect.y)..<Int(rect.bottom) {
            var n = 0
            for x in Int(rect.x)..<Int(rect.right) where isInk(x, y) { n += 1 }
            rows.append(Float(n))
        }
        guard let first = rows.firstIndex(where: { $0 > 0 }),
              let last = rows.lastIndex(where: { $0 > 0 })
        else { return [] }
        return Array(rows[first...last])
    }

    /// 矩形内で描かれた画素の y 重心を、矩形内の相対位置 (0 = 上端, 1 = 下端) で返す。
    /// 同じ図形を 2 か所に描いて重心を比べれば、上下が反転していないか判定できる。
    func inkCentroidY(in rect: Rect) -> Float? {
        var sum: Float = 0
        var n = 0
        for y in Int(rect.y)..<Int(rect.bottom) {
            for x in Int(rect.x)..<Int(rect.right) where isInk(x, y) {
                sum += Float(y)
                n += 1
            }
        }
        guard n > 0, rect.h > 0 else { return nil }
        return (sum / Float(n) - rect.y) / rect.h
    }

    /// 矩形内の画素の平均色 (背景も含めた素の平均)。
    func meanColor(in rect: Rect) -> (r: Float, g: Float, b: Float) {
        var sr = 0, sg = 0, sb = 0, n = 0
        for y in Int(rect.y)..<Int(rect.bottom) {
            for x in Int(rect.x)..<Int(rect.right) {
                let c = rgb(x, y)
                sr += c.r; sg += c.g; sb += c.b; n += 1
            }
        }
        let d = Float(max(1, n))
        return (Float(sr) / d, Float(sg) / d, Float(sb) / d)
    }
}

/// 1 つの敵対的検査。
///
/// - `draw` は与えられた矩形の中だけに描く (他セルを汚さない)。
/// - `verify` は同じ矩形を読んで判定する。時間に依存しないこと (毎フレーム同じ絵になる)。
@MainActor
struct Check {
    /// probe のキーになる識別子。`plane.item` 形式。
    let id: String
    /// セルに出す短い名前。
    let title: String
    /// 何を期待しているか (README と Issue にそのまま使える文)。
    let expect: String
    let draw: (Rect) -> Void
    let verify: (Rect, PixelReader) -> Verdict
}

/// 検査面 (キー 1 つ分の 1 画面)。
@MainActor
struct Plane {
    let key: String
    let title: String
    let checks: [Check]
}
