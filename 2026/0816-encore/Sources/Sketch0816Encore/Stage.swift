import Foundation
import metaphor

/// 影絵劇場の絵。舞台 2 面と、その下の進行表。
///
/// 描画はここに閉じ、`Troupe` は「予約された動き」だけを持つ。
/// `Silhouette` は `Interpolatable` なので、役者の姿勢は 1 本の `Tween` から丸ごと出てくる。
@MainActor
enum Stage {

    // MARK: - 寸法

    /// 舞台 1 面ぶんの矩形（間口と奥行き）。
    struct Frame {
        let x: Float, y: Float, w: Float, h: Float
        var floor: Float { y + h }
        var right: Float { x + w }
    }

    static func frame(panel: Int) -> Frame {
        let x0 = Float(panel) * 640
        return Frame(x: x0 + 46, y: 96, w: 548, h: 356)
    }

    /// 役者の立ち位置。舞台の座標系で返す（`Troupe` に渡して `Tween` の to にする）。
    static func marks(panel: Int) -> [Silhouette] {
        let f = frame(panel: panel)
        let cx = f.x + f.w / 2
        return [
            Silhouette(x: cx - 128, y: f.floor - 16, lean: -0.04, open: 0),
            Silhouette(x: cx, y: f.floor - 6, lean: 0, open: 0),
            Silhouette(x: cx + 128, y: f.floor - 16, lean: 0.04, open: 0),
        ]
    }

    /// 袖。壊れた座組はアンコールでここへ巻き戻り、そのまま凍る。
    /// **完全に隠さない**のがこの作品の肝で、「出てこない役者」が見えている必要がある。
    static func wings(panel: Int) -> [Silhouette] {
        let f = frame(panel: panel)
        return [
            Silhouette(x: f.x + 26, y: f.floor - 16, lean: 0.30, open: 0),
            Silhouette(x: f.right - 26, y: f.floor - 6, lean: -0.30, open: 0),
            Silhouette(x: f.x + 26, y: f.floor - 16, lean: 0.30, open: 0),
        ]
    }

    // MARK: - 色

    enum Ink {
        static let house = Color(r: 0.055, g: 0.047, b: 0.043, a: 1)      // 客席の闇
        static let skyTop = Color(r: 0.86, g: 0.58, b: 0.24, a: 1)        // 背景幕の上
        static let skyBottom = Color(r: 0.42, g: 0.17, b: 0.13, a: 1)     // 背景幕の下
        static let silhouette = Color(r: 0.05, g: 0.035, b: 0.035, a: 1)  // 影絵
        static let curtain = Color(r: 0.36, g: 0.07, b: 0.10, a: 1)
        static let curtainDark = Color(r: 0.22, g: 0.04, b: 0.06, a: 1)
        static let brass = Color(r: 0.52, g: 0.40, b: 0.22, a: 1)
        static let paper = Color(r: 0.11, g: 0.10, b: 0.09, a: 1)
        static let ink = Color(r: 0.91, g: 0.86, b: 0.76, a: 1)
        static let inkDim = Color(r: 0.50, g: 0.46, b: 0.40, a: 1)
        static let alarm = Color(r: 0.86, g: 0.30, b: 0.24, a: 1)
        static let good = Color(r: 0.47, g: 0.72, b: 0.47, a: 1)
    }

    // MARK: - 舞台

    static func drawHouse(_ s: some Sketch) {
        s.background(Ink.house)
        // 客席側の床板。舞台の下端から手前へ、わずかに明るく
        s.noStroke()
        s.fill(Color(r: 0.09, g: 0.075, b: 0.068, a: 1))
        s.rect(0, 462, s.width, 22)
    }

    /// 舞台 1 面。背景幕 → 役者 → 引き幕 → 額縁 の順に重ねる。
    static func drawStage(_ s: some Sketch, troupe: Troupe, panel: Int) {
        let f = frame(panel: panel)

        // 背景幕。上が明るい夕景のグラデーション
        s.noStroke()
        s.linearGradient(f.x, f.y, f.w, f.h, Ink.skyTop, Ink.skyBottom, axis: .vertical)

        // 遠景の丘。影絵の奥行きを作るためだけの飾り
        s.fill(Color(r: 0.30, g: 0.12, b: 0.11, a: 1))
        s.beginShape()
        s.vertex(f.x, f.floor)
        s.vertex(f.x, f.floor - 52)
        for i in 0...24 {
            let t = Float(i) / 24
            let x = f.x + f.w * t
            let y = f.floor - 52 - 26 * sin(t * 5.4 + Float(panel) * 1.7) * 0.5 - 14 * sin(t * 2.1)
            s.vertex(x, y)
        }
        s.vertex(f.right, f.floor)
        s.endShape(.close)

        // 舞台床
        s.fill(Color(r: 0.13, g: 0.07, b: 0.06, a: 1))
        s.rect(f.x, f.floor - 18, f.w, 18)

        // 役者（影絵）
        for i in troupe.entrances.indices {
            drawActor(s, pose: troupe.pose(i), clip: f)
        }

        // 引き幕。開き 0…1 で左右へ割れる
        drawCurtain(s, f: f, open: troupe.curtainOpen)

        // 額縁
        s.noFill()
        s.stroke(Ink.brass)
        s.strokeWeight(3)
        s.rect(f.x - 3, f.y - 3, f.w + 6, f.h + 6, 4)
        s.noStroke()
    }

    /// 引き幕。左右のパネルが外へ滑る。
    private static func drawCurtain(_ s: some Sketch, f: Frame, open: Float) {
        let shut = max(0, min(1, 1 - open))
        let panelW = f.w / 2 * shut
        guard panelW > 0.5 else { return }

        s.noStroke()
        for side in 0..<2 {
            let x = side == 0 ? f.x : f.right - panelW
            s.fill(Ink.curtain)
            s.rect(x, f.y, panelW, f.h)
            // 襞。幕らしさはこれだけで出る
            s.fill(Ink.curtainDark)
            var fold: Float = 14
            while fold < panelW {
                s.rect(x + fold, f.y, 5, f.h)
                fold += 30
            }
        }
        // 幕の合わせ目に落ちる影
        if shut > 0.02 {
            s.fill(Color(r: 0, g: 0, b: 0, a: 0.35))
            s.rect(f.x + panelW - 6, f.y, 6, f.h)
            s.rect(f.right - panelW, f.y, 6, f.h)
        }
    }

    /// 影絵の役者ひとり。`Silhouette` の 4 つの値だけで決まる。
    private static func drawActor(_ s: some Sketch, pose: Silhouette, clip: Frame) {
        // 舞台の外へはみ出す姿勢は描かない（袖より外は客席から見えない体）
        guard pose.x > clip.x - 40, pose.x < clip.right + 40 else { return }

        s.push()
        s.translate(pose.x, pose.y)
        s.rotate(pose.lean)   // 足元を軸に上体が傾く = お辞儀
        s.noStroke()
        s.fill(Ink.silhouette)

        // 裾（衣。下ほど広がる釣鐘形）
        s.beginShape()
        s.vertex(-27, 0)
        s.vertex(-15, -68)
        s.vertex(-11, -94)
        s.vertex(11, -94)
        s.vertex(15, -68)
        s.vertex(27, 0)
        s.endShape(.close)

        // 頭と結い
        s.circle(0, -110, 25)
        s.ellipse(0, -124, 20, 12)

        // 腕と扇。開き 0…1 が扇の角度になる
        let hand = SIMD2<Float>(20 + pose.open * 12, -84 - pose.open * 10)
        s.stroke(Ink.silhouette)
        s.strokeWeight(7)
        s.line(9, -88, hand.x, hand.y)
        s.noStroke()
        if pose.open > 0.02 {
            let span = pose.open * 1.9
            s.fill(Ink.silhouette)
            s.arc(hand.x, hand.y, 62, 62, -0.5 - span / 2, -0.5 + span / 2, .pie)
        }

        s.pop()
    }

    // MARK: - 進行表

    /// 進行表 1 面。各 `Tween` の状態と値を、そのまま紙に刷った体で並べる。
    static func drawCueSheet(_ s: some Sketch, troupe: Troupe, panel: Int, broken: Bool) {
        let f = frame(panel: panel)
        let x = f.x
        let y: Float = 492
        let w = f.w
        let h: Float = 214

        s.noStroke()
        s.fill(Ink.paper)
        s.rect(x, y, w, h, 3)
        s.noFill()
        s.stroke(broken ? Ink.alarm : Ink.brass)
        s.strokeWeight(1)
        s.rect(x, y, w, h, 3)
        s.noStroke()

        s.textFont("Menlo")
        s.textAlign(.left, .baseline)

        // 見出し
        s.fill(Ink.ink)
        s.textSize(15)
        s.text(troupe.title, x + 14, y + 24)
        s.fill(broken ? Ink.alarm : Ink.inkDim)
        s.textSize(11)
        s.text(troupe.note, x + 14, y + 41)

        s.fill(Ink.inkDim)
        s.textSize(11)
        s.text("第 \(troupe.performance) 公演   t=\(String(format: "%5.1f", troupe.elapsed))s", x + w - 168, y + 24)

        // 行
        var row = y + 62
        line(s, x, row, "幕（上げ）", troupe.state(of: troupe.curtainUp), troupe.curtainUp.value, w)
        row += 19
        line(s, x, row, "幕（下げ）", troupe.state(of: troupe.curtainDown), troupe.curtainDown.value, w)
        row += 23
        for i in troupe.entrances.indices {
            let ent = troupe.entrances[i]
            // 立ち位置までの到達率。壊れた座組は 0 のまま動かない
            let goal = troupe.pose(i)
            let progress = ent.isComplete ? 1 : normalized(ent.value.x, troupe.wings[i].x, goal.x)
            line(s, x, row, "役者 \(i + 1) 出", troupe.state(of: ent), progress, w)
            row += 19
        }
        row += 4
        for i in troupe.flourishes.indices {
            line(s, x, row, "所作 \(i + 1)", troupe.state(of: troupe.flourishes[i]),
                 troupe.flourishes[i].value, w)
            row += 19
        }
    }

    private static func normalized(_ v: Float, _ a: Float, _ b: Float) -> Float {
        guard abs(b - a) > 0.001 else { return 0 }
        return max(0, min(1, (v - a) / (b - a)))
    }

    /// 進行表の 1 行: 名前 / 状態 / 値のバー。
    private static func line(_ s: some Sketch, _ x: Float, _ y: Float,
                             _ name: String, _ state: String, _ value: Float, _ w: Float) {
        s.textSize(11)
        s.fill(Ink.inkDim)
        s.text(name, x + 14, y)

        // 状態。RUN なのにバーが動かない行が、この作品の見どころ
        switch state.trimmingCharacters(in: .whitespaces) {
        case "DONE": s.fill(Ink.good)
        case "RUN": s.fill(Ink.ink)
        default: s.fill(Color(r: 0.34, g: 0.31, b: 0.28, a: 1))
        }
        s.text(state, x + 106, y)

        // 値のバー
        let bx = x + 156
        let bw = w - 172
        s.fill(Color(r: 0.18, g: 0.16, b: 0.15, a: 1))
        s.rect(bx, y - 9, bw, 10, 2)
        let filled = max(0, min(1, value)) * bw
        if filled > 0.5 {
            s.fill(Ink.brass)
            s.rect(bx, y - 9, filled, 10, 2)
        }
        // 数値はバーの中に重ねる。行間へ逃がすと 1 つ上の行と重なる
        s.textSize(10)
        s.fill(Ink.ink)
        s.textAlign(.right, .baseline)
        s.text(String(format: "%.3f", value), bx + bw - 5, y - 1)
        s.textAlign(.left, .baseline)
    }

    // MARK: - 表題と注記

    static func drawChrome(_ s: some Sketch, checkSummary: String, failed: [String],
                           tweenCount: Int, encoreHint: String) {
        s.textFont("Helvetica Neue")
        s.textAlign(.left, .baseline)
        s.fill(Ink.ink)
        s.textSize(17)
        s.text("ENCORE — 予約された動きだけでできた影絵劇場", 46, 62)

        s.fill(Ink.inkDim)
        s.textSize(11)
        s.text("同じ振付・同じ Tween。違いはアンコールで tweenManager へ登録し直すかどうかだけ", 46, 80)

        s.textAlign(.right, .baseline)
        s.fill(failed.isEmpty ? Ink.good : Ink.alarm)
        s.textSize(12)
        s.text(checkSummary, 1234, 62)
        s.fill(Ink.inkDim)
        s.textSize(11)
        s.text("context.tweenManager.count = \(tweenCount)   \(encoreHint)", 1234, 80)
        if !failed.isEmpty {
            s.fill(Ink.alarm)
            s.textSize(10)
            s.text(failed.joined(separator: "  "), 1234, 712)
        }
        s.textAlign(.left, .baseline)
    }
}
