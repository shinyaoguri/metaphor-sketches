import Foundation
import metaphor

// 0816-galley — ゲラ刷り
//
// 両端揃えの組版機を、metaphor の**公開の計量 API だけ**で書いた。
// 語間は textWidth() だけで配分し、行送りは textAscent() + textDescent() だけで決める。
// 描画側の内部量には触れない。
//
//   測り値が正しければ、組んだ段の右端は一直線に揃う。狂えばほつれる。
//
// 紙面は自分で loadPixels() して読み戻し、狂った箇所に朱を入れる。
// 校正刷りが「刷ってから直す」ためのものであるように、この紙面は
// 「組んでから測る」ためのもの。
//
// 判定は 2 系統に出る:
//   - 紙面: 欄外の一覧 (OK / FAIL) と、ずれた場所を指す朱
//   - probe: frame.json の custom に `check.<ID>` として全件。AI はこちらを一次証拠にする
//     (標準出力にも同じ内容が出るので、swift run のログからも拾える)

@main
final class Sketch0816Galley: Sketch {

    var config: SketchConfig {
        SketchConfig(width: 1280, height: 800, title: "0816-galley")
    }

    // MARK: - 色

    /// 紙。`PixelReader` の ink 判定の基準でもあるので、墨と十分に離す。
    static let paper = (r: 236, g: 231, b: 221)
    /// 墨。**読み戻しで拾うのはこの色だけ。**
    static let sumi = (r: 26, g: 24, b: 22)
    /// 朱 (校正の直し)。判定より後に描く。
    static let shu = (r: 190, g: 44, b: 36)
    /// 非再現青 (罫・格子)。同じく判定より後に描く。
    static let ao = (r: 126, g: 152, b: 186)
    /// 欄外の細字。
    static let sumiThin = (r: 118, g: 110, b: 100)

    /// 文字の色を決める。
    ///
    /// **v0.9.0 では `fill()` だけでは効かない。** `drawTextFromAtlas` は頂点色に
    /// `fillColor` ではなく `tintColor` を使っており、tint 未設定だと白のまま描かれる
    /// (`Canvas2DImage.swift:186` の `let tint = hasTint ? tintColor : SIMD4(1,1,1,1)`)。
    /// 既報の [metaphor#516](https://github.com/shinyaoguri/metaphor/issues/516) で、
    /// main では 693d8ed により修正済みだが v0.9.0 (2026-08-10) には入っていない
    /// (修正は 2026-08-12)。この作品は 0.9.0 に pin しているので tint() を併用して回避する。
    ///
    /// 回避しないと紙面は白い文字だらけになり、読み戻しの ink 判定も紙との差が
    /// 77 しか出ず (墨なら 616) 閾値ぎりぎりになる。
    func textColor(_ c: (r: Int, g: Int, b: Int)) {
        fill(Float(c.r), Float(c.g), Float(c.b))
        tint(Float(c.r), Float(c.g), Float(c.b))
    }

    func inkFill() { textColor(Self.sumi) }
    func redFill() { textColor(Self.shu) }
    func thinFill() { textColor(Self.sumiThin) }
    func redStroke() { stroke(Float(Self.shu.r), Float(Self.shu.g), Float(Self.shu.b)) }
    func blueStroke() { stroke(Float(Self.ao.r), Float(Self.ao.g), Float(Self.ao.b)) }

    // MARK: - 時間の刻み (面ごと)

    /// 組み上がるまで。
    static let revealFrames: Int = 84
    /// 読み戻して判定するフレーム (組み終わってから)。
    static let judgeFrame: Int = 96
    /// 朱が入りきるまで。
    static let markFrames: Int = 40
    /// 面 1 つの尺。
    static let pageFrames: Int = 372

    // MARK: - 状態

    /// 組み上がった段 (面に入ったときだけ組み直す)。
    var columnLines: [SetLine] = []
    var columnWordCount: Int = 0

    /// 純計量の検査 (G 群)。setup() で 1 回だけ。
    var instrument: [Finding] = []
    /// 面ごとの読み戻し検査 (P 群)。面に入って組み終わった最初のフレームで 1 回だけ。
    var pageFindings: [Int: [Finding]] = [:]

    var page: Int = 0
    var enteredFrame: Int = 0
    var paused: Bool = false

    /// この面へ入ってからのフレーム数。
    var elapsed: Int { frameCount - enteredFrame }

    // MARK: - 観測の口

    private let env = ProcessInfo.processInfo.environment
    /// 面ごとに 1 枚書き出して巡回を短縮する。
    private var shotsMode: Bool { env["GALLEY_SHOTS"] == "1" }
    /// 検査の実測値を 1 行ずつ標準出力へ。
    private var traceMode: Bool { env["GALLEY_TRACE"] == "1" }
    /// GIF 用の連番 PNG。
    private var framesDir: String? { env["GALLEY_FRAMES"] }
    /// textSize 掃引の CSV。
    private var sweepMode: Bool { env["GALLEY_SWEEP"] == "1" }
    /// 落ちうる既知の穴を、頼んだときだけ再現する。
    private var trap: String? { env["GALLEY_TRAP"] }

    private var recording = false

    // MARK: - Setup

    func setup() {
        frameRate(60)
        textFont(Self.defaultFont)

        emit("== 0816-galley ==")
        emit("metaphor 0.9.0 / 既定フォント \(Self.defaultFont) / 等幅の物差し \(Self.monoFont)")

        // 純計量の検査。描画も時計も使わないので、ここで確定する。
        instrument = runInstrument()
        emit("-- 計量 (G) --")
        for f in instrument { emit("[\(f.id)] \(f.verdict.line)") }

        if sweepMode { runSweep() }
        if let name = trap { runTrap(name) }

        layoutColumns()
        // 撮影のとき、見たい面から始められるようにする (GIF は 1 面ぶんで十分なので、
        // 5 面ぶん回してから切り出すより速い)。
        if let n = env["GALLEY_PAGE"], let i = Int(n), (1...Page.allCases.count).contains(i) {
            page = i - 1
        }
        enteredFrame = frameCount

        if let dir = framesDir {
            // saveFrame(_:) は渡した名前へ無条件で ~/Desktop/ を前置する (metaphor#757) が、
            // beginFrameRecord(directory:) は絶対パスを尊重する。
            beginFrameRecord(directory: dir)
            recording = true
        }
    }

    // MARK: - Draw

    func draw() {
        background(Float(Self.paper.r), Float(Self.paper.g), Float(Self.paper.b))

        let t = min(1, Float(elapsed) / Float(Self.revealFrames))
        let current = Page(rawValue: page) ?? .columns

        // 1. 墨だけを刷る。**この時点で紙の上にあるのは紙と墨だけ** (読み戻しの前提)。
        switch current {
        case .columns: composeColumns(upTo: Int(Float(columnWordCount) * ease(t)))
        case .display: composeDisplay(reveal: Float(Copy.headings.count) * ease(t) + 0.001)
        case .grid: composeGrid(reveal: Float(Copy.gridLines.count) * ease(t) + 0.001)
        case .specimen: composeSpecimen(reveal: Float(Self.specimenSizes.count) * ease(t) + 0.001)
        case .oddments: composeOddments(reveal: Float(Copy.oddments.count) * ease(t) + 0.001)
        }

        // 2. 組み終わったら 1 回だけ読み戻して判定する。
        if pageFindings[page] == nil && elapsed >= Self.judgeFrame {
            loadPixels()
            let px = PixelReader(w: Int(width), h: Int(height), buf: pixels,
                                 paper: Self.paper, inkThreshold: 60)
            let found: [Finding]
            switch current {
            case .columns: found = proofColumns(px)
            case .display: found = proofDisplay(px)
            case .grid: found = proofGrid(px)
            case .specimen: found = proofSpecimen(px)
            case .oddments: found = proofOddments(px)
            }
            pageFindings[page] = found
            emit("-- \(current.title) (\(current.caption)) --")
            for f in found { emit("[\(f.id)] \(f.verdict.line)") }
            // 書き出しは完了の合図より先に。probe.sh は「self-check 完了」を見て
            // プロセスを止めるので、後に置くと最後の面が書き出されない。
            if shotsMode { saveFrame("galley-\(page + 1).png") }
            if pageFindings.count == Page.allCases.count { emit("self-check 完了") }
        }

        // 3. 罫・朱・欄外は判定より後 (先に描くと ink 判定に混ざる)。
        if let found = pageFindings[page] {
            let m = min(1, Float(elapsed - Self.judgeFrame) / Float(Self.markFrames))
            drawGuides(current)
            drawMarks(found, amount: m)
        }
        drawChrome(current)

        // 4. 巡回
        if !paused && elapsed >= Self.pageFrames { turn(to: (page + 1) % Page.allCases.count) }

        // 5. probe へ全件出す (frame.json の custom に載る)
        for f in instrument { probe("check.\(f.id)", f.verdict.line) }
        for (_, fs) in pageFindings { for f in fs { probe("check.\(f.id)", f.verdict.line) } }
        probe("page", current.title)
        probe("judged.pages", pageFindings.count)
        probe("fail.count", allFindings.filter { $0.verdict.isFail }.count)

        if recording && frameCount > 1200 { endFrameRecord(); recording = false }
    }

    var allFindings: [Finding] {
        instrument + Page.allCases.compactMap { pageFindings[$0.rawValue] }.flatMap { $0 }
    }

    private func ease(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    func turn(to next: Int) {
        page = next
        enteredFrame = frameCount
        if next == Page.columns.rawValue { layoutColumns() }
    }

    func keyPressed() {
        guard let k = key else { return }
        switch k {
        case "1", "2", "3", "4", "5":
            if let n = Int(String(k)) { turn(to: n - 1) }
        case " ": paused.toggle()
        case "r": pageFindings.removeAll(); turn(to: page)   // 判定をやり直す
        default: break
        }
    }

    // MARK: - 罫

    /// 版面の見当と、面ごとの基準線。**判定より後に描くこと。**
    private func drawGuides(_ p: Page) {
        noFill()
        blueStroke()
        strokeWeight(1)

        // 版面の四隅 (トンボのつもり)
        let a = Page.area
        let t: Float = 14
        line(a.x, a.y - t, a.x, a.y); line(a.x - t, a.y, a.x, a.y)
        line(a.right, a.y - t, a.right, a.y); line(a.right + t, a.y, a.right, a.y)
        line(a.x, a.bottom + t, a.x, a.bottom); line(a.x - t, a.bottom, a.x, a.bottom)
        line(a.right, a.bottom + t, a.right, a.bottom); line(a.right + t, a.bottom, a.right, a.bottom)

        switch p {
        case .columns:
            // 段の左右。両端揃えなら墨はこの 2 本にぴたりと収まるはず。
            for c in [Float(0), 1] {
                let x0 = a.x + (Page.columnWidth + Page.gutter) * c
                line(x0, a.y, x0, a.bottom)
                line(x0 + Page.columnWidth, a.y, x0 + Page.columnWidth, a.bottom)
            }
        case .display:
            line(a.cx, a.y, a.cx, a.y + 300)
        case .grid:
            textSize(gridSize)
            for y in gridBaselines { line(a.x - 10, y, a.right - 200, y) }
            line(a.x, valignY, a.right, valignY)
        case .specimen:
            // 三種の揃えの基準線。左揃えの起点・中央揃えの軸・右揃えの罫。
            for x in [Self.specimenLeft, Self.specimenCenter, Self.specimenRule] {
                line(x, a.y, x, a.y + 430)
            }
        case .oddments:
            line(a.x + 240, a.y, a.x + 240, a.bottom - 120)
        }
    }

    // MARK: - 朱

    /// ずれた場所を指す。`amount` は 0…1 で入りきるまでの度合い。
    private func drawMarks(_ found: [Finding], amount: Float) {
        guard amount > 0 else { return }
        redStroke()
        strokeWeight(1.6)
        noFill()
        for f in found where f.verdict.isFail {
            guard let m = f.mark else { continue }
            switch m {
            case .shiftX(let expected, let actual, let y):
                // 「ここに来るはず」に縦線、「実際に来た」へ矢羽根。
                let ax = expected + (actual - expected) * amount
                line(expected, y - 16, expected, y + 8)
                line(expected, y + 8, ax, y + 8)
                line(ax, y + 8, ax - sign(actual - expected) * 5, y + 4)
                line(ax, y + 8, ax - sign(actual - expected) * 5, y + 12)
            case .shiftY(let expected, let actual, let x):
                let ay = expected + (actual - expected) * amount
                line(x - 16, expected, x + 8, expected)
                line(x + 8, expected, x + 8, ay)
            case .ring(let r):
                let g = 3 + 3 * (1 - amount)
                rectMode(.corner)
                rect(r.x - g, r.y - g, r.w + g * 2, r.h + g * 2)
                rectMode(.corner)
            }
        }
        strokeWeight(1)
    }

    private func sign(_ v: Float) -> Float { v < 0 ? -1 : 1 }

    // MARK: - 欄外と題

    private func drawChrome(_ p: Page) {
        noStroke()
        textFont(Self.defaultFont)
        textAlign(.left, .baseline)

        // 題
        inkFill()
        textSize(21)
        text(p.title, Page.area.x, 60)
        thinFill()
        textSize(12)
        text(p.caption, Page.area.x + 132, 60)

        // 通し番号
        textAlign(.right, .baseline)
        text("\(page + 1) / \(Page.allCases.count)", Page.area.right, 60)
        textAlign(.left, .baseline)

        // 欄外 — この面の直し
        var y = Page.margin.y + 6
        inkFill()
        textSize(12)
        text("校正欄", Page.margin.x, y)
        y += 20
        for f in pageFindings[page] ?? [] {
            if f.verdict.isFail { redFill() } else { inkFill() }
            textSize(11)
            text("\(f.verdict.mark)  \(f.title)", Page.margin.x, y)
            y += 15
            thinFill()
            textSize(10)
            y = printRagged(f.verdict.detail, x: Page.margin.x + 8,
                            y: y, width: Page.margin.w - 8, maxLines: 7) + 10
        }

        // 脚注 — 計量 (G 群) は面によらないので下に置く
        y = 736
        inkFill()
        textSize(11)
        text("計量", Page.area.x, y)
        var x = Page.area.x + 40
        for f in instrument {
            if f.verdict.isFail { redFill() } else if f.verdict.isPass { inkFill() } else {
                thinFill()
            }
            textSize(10)
            let label = "\(f.id.prefix(2)) \(f.verdict.mark)"
            text(label, x, y)
            x += textWidth(label) + 16
        }

        // 総計
        let fails = allFindings.filter { $0.verdict.isFail }.count
        textAlign(.right, .baseline)
        if fails > 0 { redFill() } else { inkFill() }
        textSize(11)
        text("直し \(fails) 件 / 判定済み \(allFindings.count) 件", Page.area.right, y)
        textAlign(.left, .baseline)

        // 操作
        thinFill()
        textSize(10)
        text("1–5 面を選ぶ  /  space 止める  /  r 判定し直す", Page.area.x, 764)
    }

    /// 右を揃えずに折り返して刷る。折り返しは textWidth だけで決める。
    @discardableResult
    private func printRagged(_ s: String, x: Float, y: Float, width: Float, maxLines: Int) -> Float {
        let lh = textAscent() + textDescent()
        let comp = Compositor(measure: { self.textWidth($0) }, lineHeight: lh, columnWidth: width)
        let (lines, _) = comp.set(Copy.words(s), originX: x, firstBaseline: y,
                                  maxLines: maxLines, ragged: true)
        for line in lines {
            for p in line.placed({ self.textWidth($0) }) { text(p.word, p.x, line.baseline) }
        }
        return (lines.last?.baseline ?? y) + lh * 0.4
    }

    // MARK: - 掃引と罠

    /// textSize を細かく掃いて計量を CSV で吐く。ピクセルを使わないので単体で読める。
    private func runSweep() {
        emit("-- 掃引 (CSV) --")
        emit("size,textWidth_Rgh,ascent,descent,width_per_size,ad_per_size")
        textFont(Self.defaultFont)
        var s: Float = 8
        while s <= 512 {
            textSize(s)
            let w = textWidth(Copy.specimen)
            let a = textAscent(), d = textDescent()
            emit("\(f0(s)),\(f1(w)),\(f1(a)),\(f1(d)),\(f2(w / s)),\(f2((a + d) / s))")
            s = s < 64 ? s + 4 : s * 1.25
        }
        textSize(Page.bodySize)
    }

    /// 落ちうる入力を、頼んだときだけ通す。
    ///
    /// **常時実行してはいけない。** 検査に混ぜると作品が起動しなくなる
    /// (0816-marionette では負の iterations がこれで起動不能になった)。
    private func runTrap(_ name: String) {
        emit("-- 罠 \(name) --")
        switch name {
        case "zero":
            textSize(0)
            emit("textSize(0) → textWidth=\(f1(textWidth("Rgh"))) ascent=\(f1(textAscent()))")
        case "negative":
            textSize(-24)
            emit("textSize(-24) → textWidth=\(f1(textWidth("Rgh"))) ascent=\(f1(textAscent()))")
        case "huge":
            textSize(3000)
            emit("textSize(3000) → textWidth=\(f1(textWidth("Rgh"))) ascent=\(f1(textAscent()))")
        case "atlas":
            // 大きな号で相異なる字を大量に投入し、512×2048 のアトラスを使い切らせる。
            textSize(220)
            let many = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
            emit("textSize(220) 相異なる \(many.count) 字 → textWidth=\(f1(textWidth(many)))")
        default:
            emit("未知の罠: \(name) (zero / negative / huge / atlas)")
        }
        textSize(Page.bodySize)
    }
}
