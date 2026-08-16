import metaphor

// 5 面のゲラ。
//
// 各面は「刷る (compose)」と「読んで朱を入れる (proof)」の 2 つで完結する。
// **刷るのは墨だけ**。罫も朱も欄外も、読み戻しが済んでから描く (Proof.swift 冒頭の注記)。
//
// 判定の期待値は実装ではなく **doc の意味**から導く。たとえば縦揃えは
// 「指定した y が上端 / 中央 / ベースライン / 下端になる」という約束なので、
// ベースラインは順に y+ascent / y+ascent-(a+d)/2 / y / y-descent に来なければならない。

/// 面。
enum Page: Int, CaseIterable {
    case columns    // 段組 — 両端揃え
    case display    // 見出し — 中央揃え
    case grid       // 格子 — ベースラインと縦揃え
    case specimen   // 号数見本 — サイズ掃引と右端揃え
    case oddments   // 端物 — 退化入力

    var title: String {
        switch self {
        case .columns: return "一 段組"
        case .display: return "二 見出し"
        case .grid: return "三 格子"
        case .specimen: return "四 号数見本"
        case .oddments: return "五 端物"
        }
    }

    var caption: String {
        switch self {
        case .columns: return "textWidth() だけで語間を配分し、両端を揃える"
        case .display: return "textAlign(.center) の中心はどこか"
        case .grid: return "textAscent() + textDescent() が行の器になるか"
        case .specimen: return "号数を変えても揃えの意味が変わらないか"
        case .oddments: return "退化した入力で何が起きるか"
        }
    }

    // MARK: 版面

    /// 本文の号数。
    static let bodySize: Float = 17
    /// 版面 (刷る範囲)。
    static let area = Rect(x: 80, y: 96, w: 900, h: 610)
    /// 欄外 (朱を入れる余白)。校正刷りは直しを書き込むために右を広く空ける。
    static let margin = Rect(x: 1000, y: 96, w: 264, h: 610)
    /// 2 段組の段間。
    static let gutter: Float = 44
    static var columnWidth: Float { (area.w - gutter) / 2 }
}

extension Sketch0816Galley {

    // MARK: - 一 段組

    /// 本文を 2 段に組む。`upTo` 語まで刷る (組み上がっていく様子を見せるため)。
    func composeColumns(upTo: Int) {
        textFont(Self.defaultFont)
        textSize(Page.bodySize)
        textAlign(.left, .baseline)
        inkFill()

        var printed = 0
        for line in columnLines {
            for p in line.placed({ self.textWidth($0) }) {
                if printed >= upTo { return }
                text(p.word, p.x, line.baseline)
                printed += 1
            }
        }
    }

    /// 段組を組み直す (面に入ったときだけ呼ぶ。毎フレーム測ると textWidth の呼び出しが嵩む)。
    func layoutColumns() {
        textFont(Self.defaultFont)
        textSize(Page.bodySize)

        let ascent = textAscent()
        let descent = textDescent()
        let lh = (ascent + descent) * 1.34
        let comp = Compositor(measure: { self.textWidth($0) },
                              lineHeight: lh, columnWidth: Page.columnWidth)
        let capacity = Int((Page.area.h - 40) / lh)

        let words = Copy.words(Copy.body)
        // 段の釣り合い。先に全体を 1 段へ流して行数を数え、その半分で割り直す。
        // こうしないと原稿が段の容量に足りないとき 1 段目だけが埋まって不格好になる
        // (行数を数えるのも textWidth() 経由なので、計量に依存する点は変わらない)。
        let total = comp.set(words, originX: 0, firstBaseline: 0, maxLines: capacity * 2).lines.count
        let maxLines = min(capacity, (total + 1) / 2)

        let first = comp.set(words, originX: Page.area.x,
                             firstBaseline: Page.area.y + ascent, maxLines: maxLines)
        let second = comp.set(first.rest, originX: Page.area.x + Page.columnWidth + Page.gutter,
                              firstBaseline: Page.area.y + ascent, maxLines: maxLines)
        columnLines = first.lines + second.lines
        columnWordCount = columnLines.reduce(0) { $0 + $1.words.count }
    }

    /// 段組の朱入れ。右端の分散 (P9) と行頭の食い込み (P2)。
    func proofColumns(_ px: PixelReader) -> [Finding] {
        textSize(Page.bodySize)
        let ascent = textAscent()
        let descent = textDescent()

        var rightDev: [Float] = []
        var worstRight: (dev: Float, line: SetLine, actual: Float)?
        /// (行の語数, 右端の残差)。誤差が語ごとに溜まるなら、語数の多い行ほど残差が大きい。
        var byWordCount: [(n: Float, dev: Float)] = []

        // 帯の左右の余裕。段間 (44px) より狭くしないと、1 段目の帯が 2 段目の墨を拾う。
        // 最初は 30/90 にしていて、まさにこれで 1 段目の右端を 60px も外して誤検出した
        // (実測値が帯の右端ちょうどに張り付いていたので気付けた)。
        let slop: Float = 26

        for line in columnLines {
            // 行の器 = ベースラインの上に ascent、下に descent。
            let band = Rect(x: line.x - slop, y: line.baseline - ascent,
                            w: line.columnWidth + slop * 2, h: ascent + descent)
            guard let b = px.inkBounds(in: band) else { continue }

            if line.justified {
                let dev = b.right - line.expectedRight
                rightDev.append(dev)
                byWordCount.append((Float(line.words.count), dev))
                if worstRight == nil || abs(dev) > abs(worstRight!.dev) {
                    worstRight = (dev, line, b.right)
                }
            }
        }

        var out: [Finding] = []

        // P9 — 両端揃えの残差。作品そのもの。
        if let w = worstRight, !rightDev.isEmpty {
            let rms = (rightDev.reduce(0) { $0 + $1 * $1 } / Float(rightDev.count)).squareRoot()
            let body = "両端揃え \(rightDev.count) 行 / 右端の残差 最大=\(f1(w.dev))px RMS=\(f1(rms))px "
                + "(最悪の行は実測 x=\(f1(w.actual)) 期待 x=\(f1(w.line.expectedRight)))"
            let v: Verdict = abs(w.dev) <= 2.0 ? .pass(body) : .fail(body + " 許容=2.0px")
            out.append(Finding("P9.justify-residual", "右端のほつれ", v,
                               mark: .shiftX(expected: w.line.expectedRight, actual: w.actual,
                                             y: w.line.baseline)))
        } else {
            out.append(Finding("P9.justify-residual", "右端のほつれ", .fail("両端揃えの行が読めなかった")))
        }

        // P2 — 残差が「語ごとに溜まる」性質のものか。
        //      1 語あたりの計量誤差が積み上がっているなら、語数の多い行ほど残差が大きくなる。
        //      丸めや反エイリアスの揺らぎなら語数と無関係になるので、両者をここで見分ける。
        if byWordCount.count >= 4 {
            let n = Float(byWordCount.count)
            let mx = byWordCount.reduce(0) { $0 + $1.n } / n
            let my = byWordCount.reduce(0) { $0 + $1.dev } / n
            let cov = byWordCount.reduce(0) { $0 + ($1.n - mx) * ($1.dev - my) }
            let vx = byWordCount.reduce(0) { $0 + ($1.n - mx) * ($1.n - mx) }
            let vy = byWordCount.reduce(0) { $0 + ($1.dev - my) * ($1.dev - my) }
            let slope = vx > 0 ? cov / vx : 0
            let r = (vx > 0 && vy > 0) ? cov / (vx * vy).squareRoot() : 0
            let body = "両端揃え \(byWordCount.count) 行 / 語数と残差の相関 r=\(f2(r)) 傾き=\(f2(slope))px/語 (平均語数=\(f1(mx)) 平均残差=\(f1(my))px)"
            // 相関が強く傾きも有意なら、語ごとの計量誤差が溜まっている。
            let accumulates = abs(r) > 0.6 && abs(slope) > 0.15
            out.append(Finding("P2.drift-accumulates", "誤差の溜まり方",
                               accumulates ? .fail(body + " — 1 語ごとに誤差が積み上がっている")
                                           : .pass(body + " — 語数に相関しない (丸め由来の揺らぎ)")))
        }
        return out
    }

    // MARK: - 二 見出し

    func composeDisplay(reveal: Float) {
        textFont(Self.defaultFont)
        textAlign(.center, .baseline)
        inkFill()
        let size: Float = 66
        textSize(size)
        let a = textAscent(), d = textDescent()
        let lh = (a + d) * 1.15
        var y = Page.area.y + a + 90
        for (i, s) in Copy.headings.enumerated() {
            if Float(i) < reveal { text(s, Page.area.cx, y) }
            y += lh
        }
    }

    /// 中央揃えの基準。doc は「指定した x が文字列の中心になる」。
    func proofDisplay(_ px: PixelReader) -> [Finding] {
        textSize(66)
        let a = textAscent(), d = textDescent()
        let lh = (a + d) * 1.15
        var y = Page.area.y + a + 90

        var rows: [String] = []
        var worst: (dev: Float, actual: Float, y: Float)?
        for s in Copy.headings {
            let band = Rect(x: Page.area.x, y: y - a, w: Page.area.w, h: a + d)
            if let b = px.inkBounds(in: band) {
                let dev = b.cx - Page.area.cx
                rows.append("\"\(s)\" 中心=\(f1(b.cx)) ずれ=\(f1(dev))")
                if worst == nil || abs(dev) > abs(worst!.dev) { worst = (dev, b.cx, y) }
            }
            y += lh
        }

        guard let w = worst else {
            return [Finding("P3.center-basis", "中央揃えの基準", .fail("見出しが読めなかった"))]
        }
        let body = "段の中心 x=\(f1(Page.area.cx)) / " + rows.joined(separator: " / ") + " | 最大ずれ=\(f1(w.dev))px"
        let v: Verdict = abs(w.dev) <= 2.0 ? .pass(body) : .fail(body + " 許容=2.0px")
        return [Finding("P3.center-basis", "中央揃えの基準", v,
                        mark: .shiftX(expected: Page.area.cx, actual: w.actual, y: w.y))]
    }

    // MARK: - 三 格子

    /// 行の器を `textAscent() + textDescent()` から作り、格子に載せる。
    var gridSize: Float { Page.bodySize * 1.7 }
    var gridBaselines: [Float] {
        textFont(Self.defaultFont)
        textSize(gridSize)
        let lh = (textAscent() + textDescent()) * 1.5
        return (0..<Copy.gridLines.count).map { Page.area.y + textAscent() + 40 + lh * Float($0) }
    }
    /// 縦揃えの見本を置く y (格子の下)。
    var valignY: Float { Page.area.y + 330 }

    func composeGrid(reveal: Float) {
        textFont(Self.defaultFont)
        textSize(gridSize)
        textAlign(.left, .baseline)
        inkFill()
        for (i, s) in Copy.gridLines.enumerated() where Float(i) < reveal {
            text(s, Page.area.x, gridBaselines[i])
        }

        // 縦揃えの見本。同じ y へ 4 通りで刷り、器がどう動くかを見る。
        guard reveal >= Float(Copy.gridLines.count) else { return }
        textSize(Page.bodySize * 1.5)
        let sample = "Hgjpq"
        let step = Page.area.w / 4
        for (i, v) in Self.valigns.enumerated() {
            textAlign(.left, v.mode)
            text(sample, Page.area.x + step * Float(i) + 10, valignY)
        }
        textAlign(.left, .baseline)
    }

    static let valigns: [(name: String, mode: TextAlignV)] = [
        ("top", .top), ("center", .center), ("baseline", .baseline), ("bottom", .bottom),
    ]

    func proofGrid(_ px: PixelReader) -> [Finding] {
        var out: [Finding] = []

        // P5 — ascent/descent は行の器。ink がその外へ出れば行同士がぶつかる。
        textSize(gridSize)
        let a = textAscent(), d = textDescent()
        var over: [String] = []
        var worstOver: Float = 0
        var slack: [String] = []
        var overMark: ProofMark?
        // 帯は「隣の行との中間まで」に限る。器より広く読まないと はみ出しを検出できないが、
        // 広げすぎると隣の行の墨を拾って自分の判定を壊す (最初の実装がこれで誤検出した)。
        let gridGap = (a + d) * 1.5           // gridBaselines の行送り
        let halfGap = (gridGap - (a + d)) / 2 // 器の外に取れる余地
        for (i, s) in Copy.gridLines.enumerated() {
            let base = gridBaselines[i]
            let band = Rect(x: Page.area.x - 10, y: base - a - halfGap,
                            w: Page.area.w - 210, h: a + d + halfGap * 2)
            guard let b = px.inkBounds(in: band) else { continue }
            let above = (base - a) - b.y          // 正 = 器の上へはみ出した量
            let below = b.bottom - (base + d)     // 正 = 器の下へはみ出した量
            slack.append("\"\(s)\" 上=\(f1(above)) 下=\(f1(below))")
            // 輪郭が器の縁ちょうどで終わる字は、反エイリアスで 1px 外側まで色が乗る。
            // それを「はみ出し」と数えると自分の判定バグになるので 2px まで許す。
            if above > 2.0 || below > 2.0 {
                over.append("\"\(s)\" 上=\(f1(above)) 下=\(f1(below))")
                if max(above, below) > worstOver {
                    worstOver = max(above, below)
                    overMark = .ring(Rect(x: b.x - 4, y: b.y - 4, w: b.w + 8, h: b.h + 8))
                }
            }
        }
        let p5body = "器=ascent \(f1(a)) + descent \(f1(d)) = \(f1(a + d))px / はみ出し量 (正=器の外) " + slack.joined(separator: " / ")
        out.append(Finding("P5.line-box", "行の器",
                           over.isEmpty ? .pass(p5body)
                                        : .fail(p5body + " | はみ出し: " + over.joined(separator: " ") + " — 行同士がぶつかる"),
                           mark: overMark))

        // P6 — 縦揃えの相互整合。doc の意味から導いた期待:
        //      .top なら baseline = y+ascent、.center なら y+ascent-(a+d)/2、
        //      .baseline なら y、.bottom なら y-descent。ink の上端も同じだけ動くはず。
        textSize(Page.bodySize * 1.5)
        let a2 = textAscent(), d2 = textDescent()
        let step = Page.area.w / 4
        var tops: [String: Float] = [:]
        for (i, v) in Self.valigns.enumerated() {
            let band = Rect(x: Page.area.x + step * Float(i), y: valignY - (a2 + d2) * 1.6,
                            w: step - 8, h: (a2 + d2) * 3.2)
            if let b = px.inkBounds(in: band) { tops[v.name] = b.y }
        }
        if let baseTop = tops["baseline"] {
            let expected: [String: Float] = [
                "top": a2,
                "center": a2 - (a2 + d2) / 2,
                "bottom": -d2,
            ]
            var rows: [String] = []
            var worst: Float = 0
            for (name, want) in expected.sorted(by: { $0.key < $1.key }) {
                guard let t = tops[name] else { continue }
                let got = t - baseTop
                rows.append("\(name): 実測=\(f1(got)) 期待=\(f1(want)) 差=\(f1(got - want))")
                worst = max(worst, abs(got - want))
            }
            let body = "ascent=\(f1(a2)) descent=\(f1(d2)) / .baseline を基準にした ink 上端の移動量 — " + rows.joined(separator: " / ")
            out.append(Finding("P6.valign-consistency", "縦揃えの整合",
                               worst <= 2.0 ? .pass(body + " | 最大差=\(f1(worst))px")
                                            : .fail(body + " | 最大差=\(f1(worst))px 許容=2.0px")))
        } else {
            out.append(Finding("P6.valign-consistency", "縦揃えの整合", .fail("縦揃えの見本が読めなかった")))
        }
        return out
    }

    // MARK: - 四 号数見本

    /// 見本の号数。三種の揃えを横に並べて積む。
    static let specimenSizes: [Float] = [11, 15, 21, 29, 40, 55, 76, 105]
    /// 左揃えの起点。
    static var specimenLeft: Float { Page.area.x + 20 }
    /// 中央揃えの起点。
    static var specimenCenter: Float { Page.area.x + 445 }
    /// 右揃えの罫。
    static var specimenRule: Float { Page.area.right - 30 }

    /// 各号数のベースライン。
    func specimenBaselines() -> [Float] {
        textFont(Self.defaultFont)
        var ys: [Float] = []
        var y = Page.area.y + 24
        for s in Self.specimenSizes {
            textSize(s)
            y += textAscent()
            ys.append(y)
            y += textDescent() + 6
        }
        return ys
    }

    /// 同じ語を号数ごとに三種の揃えで並べる。
    ///
    /// 三点そろえば、**描画側が使っている「揃え幅」をサイドベアリング抜きで逆算できる**。
    /// 左揃えの ink 左端を基準にすれば未知の左サイドベアリングが打ち消せるため:
    ///
    ///   .left  を xL に置くと ink 左端 = xL + lsb
    ///   .right を xR に置くと ink 左端 = xR - W + lsb   → W = xR - inkL(right) + inkL(left) - xL
    ///   .center を xC に置くと ink 左端 = xC - W/2 + lsb → W = 2(xC - inkL(center) + inkL(left) - xL)
    ///
    /// この W と `textWidth()` の差が、そのまま「描く定規と測る定規の食い違い」になる。
    func composeSpecimen(reveal: Float) {
        textFont(Self.defaultFont)
        inkFill()
        let ys = specimenBaselines()
        for (i, s) in Self.specimenSizes.enumerated() where Float(i) < reveal {
            textSize(s)
            textAlign(.left, .baseline)
            text(Copy.specimen, Self.specimenLeft, ys[i])
            textAlign(.center, .baseline)
            text(Copy.specimen, Self.specimenCenter, ys[i])
            textAlign(.right, .baseline)
            text(Copy.specimen, Self.specimenRule, ys[i])
        }
        textAlign(.left, .baseline)
    }

    func proofSpecimen(_ px: PixelReader) -> [Finding] {
        textFont(Self.defaultFont)
        let ys = specimenBaselines()

        var rulerRows: [String] = []
        var consistRows: [String] = []
        var ratios: [(size: Float, ratio: Float)] = []
        var worstRuler: (dev: Float, size: Float, drawn: Float, measured: Float, y: Float) = (0, 0, 0, 0, 0)
        var worstConsist: Float = 0

        for (i, s) in Self.specimenSizes.enumerated() {
            textSize(s)
            let a = textAscent(), d = textDescent()
            let measured = textWidth(Copy.specimen)
            let top = ys[i] - a - 4
            let h = a + d + 8

            let bl = px.inkBounds(in: Rect(x: 90, y: top, w: 290, h: h))
            let bc = px.inkBounds(in: Rect(x: 390, y: top, w: 310, h: h))
            let br = px.inkBounds(in: Rect(x: 710, y: top, w: 255, h: h))
            guard let L = bl, let C = bc, let R = br else { continue }

            // サイドベアリングは 3 つの見本に共通なので、左揃えを基準にすると打ち消える。
            let base = L.x - Self.specimenLeft
            let wRight = Self.specimenRule - R.x + base
            let wCenter = 2 * (Self.specimenCenter - C.x + base)

            let dev = wRight - measured
            rulerRows.append("\(f0(s)): 揃え幅=\(f1(wRight)) textWidth=\(f1(measured)) 差=\(f1(dev))")
            if abs(dev) > abs(worstRuler.dev) { worstRuler = (dev, s, wRight, measured, ys[i]) }
            if measured > 0 { ratios.append((s, wRight / measured)) }

            let cd = wCenter - wRight
            consistRows.append("\(f0(s)): .center=\(f1(wCenter)) .right=\(f1(wRight)) 差=\(f1(cd))")
            worstConsist = max(worstConsist, abs(cd))
        }

        var out: [Finding] = []

        guard !rulerRows.isEmpty else {
            return [Finding("P1.ruler-mismatch", "定規の食い違い", .fail("号数見本が読めなかった"))]
        }

        // P1 — 描画側が揃えに使う幅と、textWidth() が返す幅。
        //      サイドベアリングは相殺済みなので、残った差は定規そのものの違い。
        //
        //      許容を 1.5px にしているのは、丸めと反エイリアスの揺らぎが ±1px だから。
        //      それを超える差が**号数によらず同じ値で出る**なら、それは揺らぎではなく系統誤差。
        //      実際 11〜105 のすべてで +2.0px ちょうどが出る (= glyphW の +2 定数)。
        let p1tol: Float = 1.5
        let p1body = rulerRows.joined(separator: " / ")
            + " | 最大差=\(f1(worstRuler.dev))px (号数 \(f0(worstRuler.size)))"
        out.append(Finding("P1.ruler-mismatch", "定規の食い違い",
                           abs(worstRuler.dev) <= p1tol ? .pass(p1body) : .fail(p1body + " 許容=\(f1(p1tol))px"),
                           mark: .shiftX(expected: Self.specimenRule - worstRuler.measured,
                                         actual: Self.specimenRule - worstRuler.drawn,
                                         y: worstRuler.y)))

        // P4 — .center と .right が同じ幅を使っているか (揃え同士の内部整合)。
        let p4body = consistRows.joined(separator: " / ") + " | 最大差=\(f1(worstConsist))px"
        out.append(Finding("P4.align-consistency", "揃え同士の整合",
                           worstConsist <= 2.0 ? .pass(p4body) : .fail(p4body + " 許容=2.0px")))

        // P8 — 号数を上げていったとき、揃え幅と textWidth の比が跳ぶ点があるか。
        //      跳べば描画経路が切り替わった疑い (アトラス → フォールバック)。
        var jump: (from: Float, to: Float, delta: Float)?
        for i in 1..<max(1, ratios.count) where jump == nil {
            let delta = ratios[i].ratio - ratios[i - 1].ratio
            if abs(delta) > 0.05 { jump = (ratios[i - 1].size, ratios[i].size, delta) }
        }
        let series = ratios.map { "\(f0($0.size)):\(f2($0.ratio))" }.joined(separator: " ")
        if let j = jump {
            out.append(Finding("P8.size-continuity", "号数の連続性",
                               .fail("揃え幅÷textWidth = \(series) | 号数 \(f0(j.from)) → \(f0(j.to)) で比が \(f2(j.delta)) 跳んだ — 描画経路が切り替わった疑い")))
        } else {
            out.append(Finding("P8.size-continuity", "号数の連続性",
                               .pass("揃え幅÷textWidth = \(series) | 号数 \(f0(Self.specimenSizes.first ?? 0))〜\(f0(Self.specimenSizes.last ?? 0)) で不連続なし")))
        }
        return out
    }

    // MARK: - 五 端物

    func oddmentBaselines() -> [Float] {
        textFont(Self.defaultFont)
        textSize(Page.bodySize * 2.2)
        let lh = (textAscent() + textDescent()) * 1.5
        return (0..<Copy.oddments.count).map { Page.area.y + textAscent() + 30 + lh * Float($0) }
    }

    func composeOddments(reveal: Float) {
        textFont(Self.defaultFont)
        textSize(Page.bodySize * 2.2)
        textAlign(.left, .baseline)
        inkFill()
        let ys = oddmentBaselines()
        for (i, o) in Copy.oddments.enumerated() where Float(i) < reveal {
            text(o.value, Page.area.x + 240, ys[i])
        }
    }

    func proofOddments(_ px: PixelReader) -> [Finding] {
        textFont(Self.defaultFont)
        textSize(Page.bodySize * 2.2)
        let a = textAscent(), d = textDescent()
        let ys = oddmentBaselines()
        let originX = Page.area.x + 240

        var rows: [String] = []
        var out: [Finding] = []
        var overhangMark: ProofMark?
        var overhangVerdict: Verdict = .look("判定材料が読めなかった")

        for (i, o) in Copy.oddments.enumerated() {
            let band = Rect(x: originX - 40, y: ys[i] - a * 1.3, w: Page.area.w - 240, h: (a + d) * 1.7)
            let measured = textWidth(o.value)
            let b = px.inkBounds(in: band)
            let seen = b.map { "ink \(f0($0.w))x\(f0($0.h)) 左端ずれ=\(f1($0.x - originX))" } ?? "ink 無し"
            rows.append("\(o.label): textWidth=\(f1(measured)) \(seen)")

            // P7 — advance より広い字が切れていないか。
            //      グリフのビットマップ幅は ceil(advance)+2 なので、外へ張り出す字は
            //      右端が削れる。左に食い込む字は左端が削れる。
            if o.label == "advance より広い字", let bb = b {
                // W を 3 つ。1 文字ぶんの幅を測り、3 倍と ink 幅を比べる。
                let one = textWidth("W")
                let expect3 = textWidth("WWW")
                let body = "\"WWW\": textWidth=\(f1(expect3)) (W 単体=\(f1(one)) ×3=\(f1(one * 3))) ink幅=\(f1(bb.w)) 差=\(f1(bb.w - expect3))"
                overhangVerdict = abs(bb.w - expect3) <= 3.0 ? .pass(body) : .fail(body + " 許容=3.0px")
                if abs(bb.w - expect3) > 3.0 {
                    overhangMark = .ring(Rect(x: bb.x - 4, y: bb.y - 4, w: bb.w + 8, h: bb.h + 8))
                }
            }
        }
        out.append(Finding("P7.overhang-clip", "はみ出す字の欠け", overhangVerdict, mark: overhangMark))

        // P10 — 退化入力で落ちずに済んだか。ここへ到達している時点で落ちてはいない。
        //       何が起きたか (無言で消える / 連結される) を数値で残す。
        out.append(Finding("P10.degenerate", "退化入力", .look(rows.joined(separator: " / "))))
        return out
    }
}
