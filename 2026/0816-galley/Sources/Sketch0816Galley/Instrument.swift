import metaphor

// 純計量の検査 (G1〜G7)。
//
// 描画も時計も使わないので、`setup()` で 1 回走らせれば結果が確定する。
// 実行のたびに同じ数値が出ることがこの群の前提 (乱数もフレーム番号も参照しない)。
//
// 判定は真偽値ではなく**実測値を含む文字列**にしてある。あとで issue に貼るとき、
// 数字がそのまま証拠になるため。

extension Sketch0816Galley {

    /// 検査に使う等幅フォント。
    ///
    /// **等幅は計量の物差しとして特別**。定義上どのグリフも advance が同一なので、
    /// 「`textWidth()` が advance 幅を返しているか」を、フォントの内部を覗かずに判定できる。
    /// advance 幅なら `textWidth("i") == textWidth("W")` になるはず。
    static let monoFont = "Menlo"
    /// 既定のフォント (Canvas2D の `currentFontFamily` 初期値)。
    static let defaultFont = "Helvetica"

    func runInstrument() -> [Finding] {
        var out: [Finding] = []
        out.append(g1WidthAdditivity())
        out.append(g2WidthSpaceTrim())
        out.append(g3WidthEmpty())
        out.append(g4WidthLinear())
        out.append(g5MetricsLinear())
        out.append(g6MonospaceAdvance())
        out.append(g7BogusFont())
        restoreTextState()
        return out
    }

    /// 検査がいじったテキスト状態を既定へ戻す (紙面の組版へ影響させない)。
    private func restoreTextState() {
        textFont(Self.defaultFont)
        textSize(Page.bodySize)
        textAlign(.left, .baseline)
    }

    // MARK: - G1 幅の加法性

    /// 語を並べて組むなら、部分の幅の和は全体の幅と一致しなければならない。
    /// 一致しないと、行に語を詰めるたびに誤差が溜まる。
    private func g1WidthAdditivity() -> Finding {
        textFont(Self.defaultFont)
        textSize(Page.bodySize)

        // カーニングが効きうる対と、効かない対を混ぜる。
        let pairs = [("A", "V"), ("T", "o"), ("W", "a"), ("n", "n"), ("Rg", "hs")]
        var worst: (pair: String, whole: Float, sum: Float, diff: Float) = ("", 0, 0, 0)
        var detail: [String] = []
        for (a, b) in pairs {
            let whole = textWidth(a + b)
            let sum = textWidth(a) + textWidth(b)
            let d = sum - whole
            detail.append("\(a)+\(b)=\(f1(sum)) vs \(a + b)=\(f1(whole)) 差\(f1(d))")
            if abs(d) > abs(worst.diff) { worst = (a + b, whole, sum, d) }
        }

        let body = "最大差 \(worst.pair): 部分の和=\(f1(worst.sum)) 全体=\(f1(worst.whole)) 差=\(f1(worst.diff))px | " + detail.joined(separator: " / ")
        // 1px は丸めで出うるので許す。それを超えるなら語を並べるたびに溜まる。
        return Finding("G1.width-additivity", "幅の加法性",
                       abs(worst.diff) <= 1.0 ? .pass(body) : .fail(body))
    }

    // MARK: - G2 空白の幅

    /// 語間を `textWidth(" ")` で測れるか。光学バウンズは両端の空白を落とすので、
    /// 落ちるなら組版側は差分で語間を取るしかない (`Compositor.naturalSpace` がそうしている)。
    private func g2WidthSpaceTrim() -> Finding {
        textFont(Self.defaultFont)
        textSize(Page.bodySize)

        let wSpace = textWidth(" ")
        let wA = textWidth("A")
        let wTrail = textWidth("A ")
        let wLead = textWidth(" A")
        let byDiff = textWidth("A A") - textWidth("AA")

        let body = "textWidth(\" \")=\(f1(wSpace)) / \"A\"=\(f1(wA)) \"A \"=\(f1(wTrail)) \" A\"=\(f1(wLead)) / 差分法の語間=\(f1(byDiff))px"
        // 空白が幅を持ち、前後に付けたぶんだけ全体が広がるのが素直な期待。
        let holdsSpace = wSpace > 0.5
        let trailCounts = (wTrail - wA) > 0.5
        let leadCounts = (wLead - wA) > 0.5
        if holdsSpace && trailCounts && leadCounts { return Finding("G2.width-space-trim", "空白の幅", .pass(body)) }
        return Finding("G2.width-space-trim", "空白の幅",
                       .fail(body + " — 空白が幅に数えられていない (語間を textWidth(\" \") では測れない)"))
    }

    // MARK: - G3 空文字列

    private func g3WidthEmpty() -> Finding {
        textFont(Self.defaultFont)
        textSize(Page.bodySize)
        let w = textWidth("")
        let body = "textWidth(\"\")=\(f1(w))px"
        return Finding("G3.width-empty", "空文字列の幅",
                       w == 0 ? .pass(body) : .fail(body + " 期待=0.0px"))
    }

    // MARK: - G4 サイズ線形性

    /// textSize を 2 倍にすれば幅も 2 倍。ここが崩れると号数を変えた瞬間に組版が破れる。
    private func g4WidthLinear() -> Finding {
        textFont(Self.defaultFont)
        let sample = "Hamburgefonstiv"
        var rows: [String] = []
        var worst: Float = 0
        for base in [Float(12), 24, 50] {
            textSize(base)
            let w1 = textWidth(sample)
            textSize(base * 2)
            let w2 = textWidth(sample)
            let ratio = w1 > 0 ? w2 / w1 : 0
            rows.append("\(f0(base))→\(f0(base * 2)): \(f1(w1))→\(f1(w2)) 比=\(f2(ratio))")
            worst = max(worst, abs(ratio - 2))
        }
        let body = rows.joined(separator: " / ") + " | 比の最大ずれ=\(f2(worst))"
        return Finding("G4.width-linear", "幅のサイズ線形性",
                       worst <= 0.02 ? .pass(body) : .fail(body + " 期待比=2.00"))
    }

    // MARK: - G5 アセント・ディセント

    /// `textAscent()` / `textDescent()` はこのリポジトリの全作品で使用 0 件。
    /// 行送りをここから作るので、サイズに線形でなければ格子が組めない。
    private func g5MetricsLinear() -> Finding {
        textFont(Self.defaultFont)
        var rows: [String] = []
        var worst: Float = 0
        var ratios: [Float] = []
        for size in [Float(12), 24, 48] {
            textSize(size)
            let a = textAscent()
            let d = textDescent()
            rows.append("size=\(f0(size)): ascent=\(f1(a)) descent=\(f1(d)) 和=\(f1(a + d))")
            ratios.append((a + d) / size)
        }
        // 同じフォントなら (ascent+descent)/size はサイズによらず一定のはず。
        if let first = ratios.first {
            for r in ratios { worst = max(worst, abs(r - first)) }
        }
        let body = rows.joined(separator: " / ") + " | (a+d)/size=" + ratios.map { f2($0) }.joined(separator: ",") + " ばらつき=\(f2(worst))"
        return Finding("G5.metrics-linear", "ascent/descent の線形性",
                       worst <= 0.02 ? .pass(body) : .fail(body))
    }

    // MARK: - G6 等幅フォントの advance

    /// **この検査がいちばん鋭い。** 等幅フォントでは定義上どのグリフも advance が同じなので、
    /// `textWidth()` が advance 幅を返しているなら `textWidth("i") == textWidth("W")` になる。
    /// 一致しないなら、返しているのは advance ではなく**インクの拡がり**であり、
    /// 文字を並べる位置決めには使えない、ということになる。
    private func g6MonospaceAdvance() -> Finding {
        textFont(Self.monoFont)
        textSize(Page.bodySize)

        let glyphs = ["i", "W", "m", ".", "l"]
        let widths = glyphs.map { textWidth($0) }
        let minW = widths.min() ?? 0
        let maxW = widths.max() ?? 0
        let spread = maxW - minW

        // n 文字分の幅も、advance なら 1 文字幅のちょうど n 倍。
        // 1 字ずつ伸ばして「1 字あたりに換算した幅」を並べると、丸めがどこで効くかが見える。
        var series: [String] = []
        var perGlyph: [String] = []
        for n in [1, 2, 4, 8, 16] {
            let w = textWidth(String(repeating: "i", count: n))
            series.append("×\(n)=\(f1(w))")
            perGlyph.append(f2(w / Float(n)))
        }
        let w1 = textWidth("i")
        let w4 = textWidth("iiii")
        let stackRatio = w1 > 0 ? w4 / w1 : 0

        let detail = zip(glyphs, widths).map { "\($0)=\(f1($1))" }.joined(separator: " ")
        let body = "\(Self.monoFont) で \(detail) | 幅の広がり=\(f1(spread))px"
            + " / \"i\" を伸ばす: " + series.joined(separator: " ")
            + " → 1 字あたり " + perGlyph.joined(separator: ", ")
            + " / \"iiii\"÷\"i\"=\(f2(stackRatio)) (等幅なら 4.00)"

        textFont(Self.defaultFont)
        if spread <= 1.0 && abs(stackRatio - 4) <= 0.05 {
            return Finding("G6.monospace-advance", "等幅の advance", .pass(body))
        }
        return Finding("G6.monospace-advance", "等幅の advance",
                       .fail(body + " — 等幅なのに字ごとに幅が違う = textWidth は advance 幅ではない"))
    }

    // MARK: - G7 存在しないフォント名

    /// 名前を間違えたときに落ちないか、何にフォールバックするか。
    /// `CTFontCreateWithName` は不明な名前でも nil を返さないので、黙って別のフォントになりうる。
    private func g7BogusFont() -> Finding {
        textSize(Page.bodySize)

        textFont(Self.defaultFont)
        let baseW = textWidth("Hamburgefonstiv")
        let baseA = textAscent()

        textFont("ZZ-NoSuchFontFamily-0816")
        let bogusW = textWidth("Hamburgefonstiv")
        let bogusA = textAscent()

        textFont(Self.defaultFont)

        let body = "既定 \(Self.defaultFont): 幅=\(f1(baseW)) ascent=\(f1(baseA)) / 不正名: 幅=\(f1(bogusW)) ascent=\(f1(bogusA))"
        guard bogusW > 0, bogusA > 0 else {
            return Finding("G7.bogus-font", "不正なフォント名",
                           .fail(body + " — 計量が 0 になり、以降のレイアウトが破綻する"))
        }
        // 落ちずに何かへフォールバックするなら実用上は妥当。何になったかは目視に回す。
        let same = abs(bogusW - baseW) < 0.5 && abs(bogusA - baseA) < 0.5
        return Finding("G7.bogus-font", "不正なフォント名",
                       .look(body + (same ? " — 既定と同じ計量へフォールバックした" : " — 既定とは別のフォントへフォールバックした")))
    }
}
