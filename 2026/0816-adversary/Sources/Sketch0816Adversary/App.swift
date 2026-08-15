import metaphor

// 0816-adversary — 敵対的仕様適合検査盤
//
// metaphor の API を「作品を作る過程でたまたま踏む」のではなく、敵対的に組み合わせて
// 仕様に反する動きを炙り出すための検査盤。各セルが 1 つの検査で、スケッチ自身が
// loadPixels() で実際のピクセルを読み、期待と照合して PASS / FAIL を判定する。
//
// 判定結果は 2 系統に出る:
//   - 画面: セル枠の色 (PASS = シアン / FAIL = 赤 / LOOK = 灰) と 1 行の実測
//   - probe: frame.json の custom に `check.<id>` として全件。AI はこちらを一次証拠にする

@main
final class Sketch0816Adversary: Sketch {
    var config: SketchConfig {
        SketchConfig(width: 1280, height: 720, title: "0816-adversary")
    }

    // MARK: - 検査盤の見た目

    /// 背景色。`PixelReader` の ink 判定の基準でもあるので、検査が使う色と十分離す。
    static let bg = (r: 10, g: 12, b: 16)
    static let passColor = (r: 70, g: 200, b: 210)
    static let failColor = (r: 245, g: 76, b: 66)
    static let lookColor = (r: 120, g: 128, b: 140)

    // MARK: - 状態

    private lazy var planes: [Plane] = [
        planeAState(),
        planeBModes(),
        planeCTransform(),
        planeDArcShape(),
        planeEColorBlend(),
        planeFTextGraphics(),
    ]

    /// 面ごとの判定結果。未判定の面は空配列。
    private var results: [[Verdict]] = []
    /// draw 側で測った値 (screenX の戻り値・textWidth など) を verify 側へ渡す一時置き場。
    var scratch: [String: Float] = [:]
    /// 面 F が使うオフスクリーンバッファ。毎フレーム作ると重いので使い回す。
    /// F8/F9 は 1 枚を共有して「フレーム内で描き換えたときの挙動」を突き、
    /// F7 は他の検査に汚されないよう専用の 1 枚を使う。
    var offscreen: Graphics?
    var offscreenSolo: Graphics?
    private var current = 0
    private var lastSwitch: Float = 0
    /// 判定は面ごとに 1 回だけ。全面が済むまでは毎フレーム次の面へ進めて一気に埋める。
    private var allJudged = false

    func setup() {
        frameRate(60)
        results = Array(repeating: [], count: planes.count)
    }

    // MARK: - Draw

    func draw() {
        background(Float(Self.bg.r), Float(Self.bg.g), Float(Self.bg.b))

        let plane = planes[current]
        let cells = layout(count: plane.checks.count)

        // 1. 検査図形を全セル分描く (この時点ではラベルも枠も描かない)
        for (i, check) in plane.checks.enumerated() where i < cells.count {
            push()
            resetStyle()
            check.draw(cells[i].canvas)
            pop()
        }

        // 2. まだ判定していない面なら、ここで 1 回だけ読み戻して全セルを判定する
        if results[current].isEmpty {
            loadPixels()
            let reader = PixelReader(
                w: Int(width), h: Int(height), buf: pixels,
                bg: Self.bg, inkThreshold: 40
            )
            var verdicts: [Verdict] = []
            for (i, check) in plane.checks.enumerated() where i < cells.count {
                verdicts.append(check.verify(cells[i].canvas, reader))
            }
            results[current] = verdicts
        }

        // 3. 枠・ラベル・ヘッダ (判定より後に描くので読み戻しには影響しない)
        resetStyle()
        drawChrome(plane: plane, cells: cells)

        // 4. 面の巡回
        advance()

        // 5. probe へ全面の結果を出す
        report()
    }

    /// 検査どうしがスタイルを汚し合わないよう、各セルの描画前に既定へ戻す。
    private func resetStyle() {
        rectMode(.corner)
        ellipseMode(.center)
        imageMode(.corner)
        colorMode(.rgb, 255)
        blendMode(.alpha)
        noTint()
        fill(255)
        stroke(255)
        noStroke()
        strokeWeight(1)
        strokeCap(.round)
        strokeJoin(.miter)
        textSize(12)
        textAlign(.left, .baseline)
        textLeading(14)
    }

    // MARK: - レイアウト

    struct Cell {
        /// セル全体 (枠を描く矩形)。
        let frame: Rect
        /// 検査が描いてよい領域。
        let canvas: Rect
    }

    private func layout(count: Int) -> [Cell] {
        let cols = 3
        let rows = max(1, (count + cols - 1) / cols)
        let margin: Float = 20
        let top: Float = 62
        let gap: Float = 12
        let cellW = (width - margin * 2 - gap * Float(cols - 1)) / Float(cols)
        let cellH = (height - top - margin - gap * Float(rows - 1)) / Float(rows)

        return (0..<count).map { i in
            let c = Float(i % cols)
            let r = Float(i / cols)
            let frame = Rect(
                x: margin + c * (cellW + gap),
                y: top + r * (cellH + gap),
                w: cellW, h: cellH
            )
            // 上 19px はタイトル、下 26px は実測の 2 行に使う。
            let canvas = Rect(
                x: frame.x + 8, y: frame.y + 19,
                w: frame.w - 16, h: frame.h - 19 - 26
            )
            return Cell(frame: frame, canvas: canvas)
        }
    }

    // MARK: - 枠とラベル

    private func drawChrome(plane: Plane, cells: [Cell]) {
        let verdicts = results[current]

        for (i, check) in plane.checks.enumerated() where i < cells.count {
            let cell = cells[i]
            let v = i < verdicts.count ? verdicts[i] : nil
            let c = frameColor(v)

            noFill()
            stroke(Float(c.r), Float(c.g), Float(c.b), 150)
            strokeWeight(1)
            rectMode(.corner)
            rect(cell.frame.x, cell.frame.y, cell.frame.w, cell.frame.h)

            noStroke()
            fill(Float(c.r), Float(c.g), Float(c.b))
            textSize(11)
            textAlign(.left, .baseline)
            text(check.title, cell.frame.x + 8, cell.frame.y + 14)

            if let v {
                fill(Float(c.r), Float(c.g), Float(c.b), 220)
                textSize(10)
                text(v.label, cell.frame.x + 8, cell.frame.bottom - 14)
            }
            fill(120, 128, 140, 190)
            textSize(9)
            text(check.expect, cell.frame.x + 8, cell.frame.bottom - 4)
        }

        // ヘッダ
        let done = results.filter { !$0.isEmpty }.count
        let fails = results.flatMap { $0 }.filter(\.isFail).count
        let passes = results.flatMap { $0 }.filter(\.isPass).count
        let total = results.flatMap { $0 }.count

        noStroke()
        fill(235, 240, 245)
        textSize(18)
        textAlign(.left, .baseline)
        text("\(plane.key) · \(plane.title)", 20, 32)

        textSize(12)
        fill(120, 128, 140)
        text("0816-adversary — 敵対的仕様適合検査盤   面 \(done)/\(planes.count) 判定済み   [1-6] 面切替 / [r] 再判定", 20, 50)

        textAlign(.right, .baseline)
        textSize(16)
        if fails > 0 {
            fill(Float(Self.failColor.r), Float(Self.failColor.g), Float(Self.failColor.b))
            text("FAIL \(fails)", width - 20, 32)
        } else {
            fill(Float(Self.passColor.r), Float(Self.passColor.g), Float(Self.passColor.b))
            text("FAIL 0", width - 20, 32)
        }
        fill(120, 128, 140)
        textSize(12)
        text("\(passes) PASS / \(total) 判定", width - 20, 50)
    }

    private func frameColor(_ v: Verdict?) -> (r: Int, g: Int, b: Int) {
        guard let v else { return (60, 66, 76) }
        switch v {
        case .pass: return Self.passColor
        case .fail: return Self.failColor
        case .visual: return Self.lookColor
        }
    }

    // MARK: - 巡回

    /// 環境変数 `ADVERSARY_PLANE=F` で、全面の判定が済んだあとその面に留まる。
    /// 検証スクリプトが目的の面のスクリーンショットを撮るために使う。
    private lazy var pinnedPlane: Int? = {
        guard let key = ProcessInfo.processInfo.environment["ADVERSARY_PLANE"] else { return nil }
        return planes.firstIndex { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }()

    private func advance() {
        if !allJudged {
            // 未判定の面が残っている間は毎フレーム進めて、起動直後に全面を埋める。
            if let next = results.firstIndex(where: \.isEmpty) {
                current = next
            } else {
                allJudged = true
                current = pinnedPlane ?? 0
                lastSwitch = time
            }
            return
        }
        if let pinned = pinnedPlane {
            current = pinned
            return
        }
        if time - lastSwitch > 5 {
            current = (current + 1) % planes.count
            lastSwitch = time
        }
    }

    func keyPressed() {
        guard let k = key else { return }
        if let n = Int(String(k)), n >= 1, n <= planes.count {
            current = n - 1
            lastSwitch = time
            allJudged = true
        }
        if k == "r" || k == "R" {
            results = Array(repeating: [], count: planes.count)
            allJudged = false
            current = 0
        }
    }

    // MARK: - probe (AI が読む一次証拠)

    private func report() {
        var failIDs: [String] = []
        var pass = 0, fail = 0, look = 0

        for (pi, plane) in planes.enumerated() {
            let verdicts = results[pi]
            guard !verdicts.isEmpty else { continue }
            for (ci, check) in plane.checks.enumerated() where ci < verdicts.count {
                let v = verdicts[ci]
                probe("check.\(check.id)", v.label)
                switch v {
                case .pass: pass += 1
                case .fail: fail += 1; failIDs.append(check.id)
                case .visual: look += 1
                }
            }
        }

        probe("summary.pass", pass)
        probe("summary.fail", fail)
        probe("summary.visual", look)
        probe("summary.planesJudged", results.filter { !$0.isEmpty }.count)
        probe("summary.planeCount", planes.count)
        probe("summary.cellCount", planes[current].checks.count)
        probe("summary.failIDs", failIDs.isEmpty ? "(none)" : failIDs.joined(separator: " "))
        probe("plane", planes[current].key)
    }
}
