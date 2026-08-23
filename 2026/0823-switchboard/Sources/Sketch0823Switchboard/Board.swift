import Foundation
import metaphor

// MARK: - 盤面の色

/// ベークライトと真鍮の交換台。数値は 0…255（このスケッチは既定の RGB レンジで通す）。
enum Palette {
    static let board: (Float, Float, Float) = (26, 21, 18)
    static let panel: (Float, Float, Float) = (38, 31, 26)
    static let panelDeep: (Float, Float, Float) = (20, 16, 14)
    static let brass: (Float, Float, Float) = (196, 162, 96)
    static let brassDim: (Float, Float, Float) = (116, 94, 54)
    static let lampOn: (Float, Float, Float) = (255, 196, 96)
    static let lampOff: (Float, Float, Float) = (58, 48, 40)
    static let alarm: (Float, Float, Float) = (214, 78, 58)
    static let ink: (Float, Float, Float) = (224, 212, 192)
    static let inkDim: (Float, Float, Float) = (146, 132, 114)
}

// MARK: - ジャック 1 口ぶんの見た目

/// 盤面に並ぶ差し込み口 1 口。
struct JackFace {
    /// ランプが何を根拠に点くか。
    enum Evidence {
        /// このスケッチが仕込んだ `post()` の到着そのもの（毎フレーム点滅する）。
        case arrival
        /// プラグインが付いているという事実だけ（Syphon の post() は計測できないので常灯）。
        case attachment
    }

    let pluginID: String
    /// 盤面に彫ってある短い名前。
    let title: String
    /// どの経路で生えるジャックか（1 行の説明）。
    let route: String
    let x: Float
    /// パッチコードが繋がっているか（provider が nil を返す口は繋がらない）。
    let patched: Bool
    let evidence: Evidence
}

extension Sketch0823Switchboard {

    // MARK: 盤面全体

    func drawBoard() {
        background(Palette.board.0, Palette.board.1, Palette.board.2)
        drawNameplate()
        drawPanelPlate()
        drawTrunk()
        for jack in jacks { drawJack(jack) }
        drawArrivalStrip()
        drawLedger()
        drawHoverCard()
    }

    // MARK: 銘板

    private func drawNameplate() {
        noStroke()
        fill(Palette.panel.0, Palette.panel.1, Palette.panel.2)
        rect(0, 0, width, 72)

        // 真鍮のモール（下端の細い帯）。
        fill(Palette.brassDim.0, Palette.brassDim.1, Palette.brassDim.2)
        rect(0, 70, width, 2)

        fill(Palette.brass.0, Palette.brass.1, Palette.brass.2)
        textAlign(.left, .baseline)
        textSize(26)
        text("SWITCHBOARD  №0823", 28, 44)

        fill(Palette.inkDim.0, Palette.inkDim.1, Palette.inkDim.2)
        textSize(12)
        textAlign(.right, .baseline)
        text("metaphor \(Metaphor.version) / metaphor-syphon \(syphonVersion)", width - 28, 30)
        text("1 枚の最終フレームが分岐して各ジャックへ落ちる — 落ちていない口はランプが消える", width - 28, 50)
        textAlign(.left, .baseline)
    }

    /// ジャックが並ぶ面。四隅にネジ。
    private func drawPanelPlate() {
        noStroke()
        fill(Palette.panel.0, Palette.panel.1, Palette.panel.2)
        rect(28, 100, width - 56, 356, 8)
        fill(Palette.panelDeep.0, Palette.panelDeep.1, Palette.panelDeep.2)
        rect(28, 452, width - 56, 3)
        for sx in [Float(48), width - 48] {
            for sy in [Float(120), Float(436)] {
                fill(Palette.brassDim.0, Palette.brassDim.1, Palette.brassDim.2)
                circle(sx, sy, 11)
                stroke(Palette.panelDeep.0, Palette.panelDeep.1, Palette.panelDeep.2)
                strokeWeight(1.5)
                line(sx - 3.5, sy, sx + 3.5, sy)
                noStroke()
            }
        }
    }

    // MARK: 幹線と分配バー

    private func drawTrunk() {
        let barY: Float = 158

        // 入口の「最終フレーム」ラベル。
        noStroke()
        fill(Palette.panelDeep.0, Palette.panelDeep.1, Palette.panelDeep.2)
        rect(28, barY - 26, 168, 52, 6)
        fill(Palette.ink.0, Palette.ink.1, Palette.ink.2)
        textSize(13)
        text("FINAL FRAME", 44, barY - 4)
        fill(Palette.inkDim.0, Palette.inkDim.1, Palette.inkDim.2)
        textSize(11)
        text("\(Int(width))×\(Int(height)) post()", 44, barY + 14)

        // 分配バー。
        stroke(Palette.brassDim.0, Palette.brassDim.1, Palette.brassDim.2)
        strokeWeight(6)
        line(196, barY, trunkOrigin.x, barY)
        noStroke()
        fill(Palette.brass.0, Palette.brass.1, Palette.brass.2)
        circle(trunkOrigin.x, barY, 16)

        // パッチコード。繋がっている口へだけ引く。
        for jack in jacks {
            if jack.patched {
                drawCord(to: jack)
            } else {
                drawDanglingPlug(near: jack)
            }
        }
    }

    /// 幹線からジャックへ垂れるパッチコード。受信中は光の玉が流れる。
    private func drawCord(to jack: JackFace) {
        // 交換台のコードらしく、いったん垂れてからソケットの左肩へ掛かる。
        // 遠い口ほど大きく垂らす（ランプの真上を通らないのはこの垂れのおかげ）。
        let p0 = trunkOrigin
        let p3 = (x: jack.x - 34, y: socketY - 20)
        let dx = p3.x - p0.x
        let sag = min(200, 70 + dx * 0.26)
        let c1 = (x: p0.x + dx * 0.30, y: p0.y + sag)
        let c2 = (x: p3.x - dx * 0.16, y: p3.y + sag * 0.22)

        let lit = jack.evidence == .arrival ? log.lit(jack.pluginID) : jack.patched
        if lit {
            stroke(Palette.brass.0, Palette.brass.1, Palette.brass.2, 210)
        } else {
            stroke(Palette.brassDim.0, Palette.brassDim.1, Palette.brassDim.2, 150)
        }
        strokeWeight(3)
        noFill()
        bezier(p0.x, p0.y, c1.x, c1.y, c2.x, c2.y, p3.x, p3.y)
        noStroke()

        guard lit else { return }
        // 到着順を位相にして玉を流す。順番が違えば玉の位置も違う = 順序が絵に出る。
        let slot = Float(log.order(of: jack.pluginID) ?? 0)
        let t = (time * 0.9 + slot * 0.12).truncatingRemainder(dividingBy: 1.0)
        let bead = cubicBezierPoint(p0, c1, c2, p3, t)
        fill(Palette.lampOn.0, Palette.lampOn.1, Palette.lampOn.2, 90)
        circle(bead.x, bead.y, 16)
        fill(255, 236, 200)
        circle(bead.x, bead.y, 7)
    }

    /// 繋がっていない口の手前で宙ぶらりんになっているプラグ。
    private func drawDanglingPlug(near jack: JackFace) {
        let p0 = trunkOrigin
        // 差されずにソケットの脇へ転がっているプラグ。
        let end = (x: jack.x - 74, y: socketY + 16)
        let dx = end.x - p0.x
        let sag = min(210, 80 + dx * 0.26)
        stroke(Palette.brassDim.0, Palette.brassDim.1, Palette.brassDim.2, 110)
        strokeWeight(3)
        noFill()
        bezier(p0.x, p0.y, p0.x + dx * 0.30, p0.y + sag, end.x - dx * 0.14, end.y + sag * 0.16, end.x, end.y)
        noStroke()
        fill(Palette.brassDim.0, Palette.brassDim.1, Palette.brassDim.2)
        circle(end.x, end.y, 12)
    }

    /// 3 次ベジェ上の点。玉を流すためだけの計算。
    private func cubicBezierPoint(
        _ p0: (x: Float, y: Float), _ p1: (x: Float, y: Float),
        _ p2: (x: Float, y: Float), _ p3: (x: Float, y: Float), _ t: Float
    ) -> (x: Float, y: Float) {
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        return (a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    // MARK: ジャック

    private func drawJack(_ jack: JackFace) {
        // Syphon の post() はこちらから計測できないので、その口だけは「付いているか」で点す。
        let lit = jack.evidence == .arrival ? log.lit(jack.pluginID) : jack.patched
        let total = log.totals[jack.pluginID] ?? 0

        // ランプ。
        if lit {
            noStroke()
            fill(Palette.lampOn.0, Palette.lampOn.1, Palette.lampOn.2, 46)
            circle(jack.x, lampY, 54)
            fill(Palette.lampOn.0, Palette.lampOn.1, Palette.lampOn.2)
            circle(jack.x, lampY, 24)
            fill(255, 244, 216)
            circle(jack.x - 3, lampY - 3, 9)
        } else {
            noStroke()
            fill(Palette.lampOff.0, Palette.lampOff.1, Palette.lampOff.2)
            circle(jack.x, lampY, 24)
            // 差さっているのに来ていない = 異常。輪だけ赤く残す。
            if jack.patched {
                noFill()
                stroke(Palette.alarm.0, Palette.alarm.1, Palette.alarm.2)
                strokeWeight(2)
                circle(jack.x, lampY, 32)
                noStroke()
            }
        }

        // 差し込み口。
        noStroke()
        fill(Palette.brassDim.0, Palette.brassDim.1, Palette.brassDim.2)
        circle(jack.x, socketY, 62)
        fill(Palette.brass.0, Palette.brass.1, Palette.brass.2)
        circle(jack.x, socketY, 54)
        fill(Palette.panelDeep.0, Palette.panelDeep.1, Palette.panelDeep.2)
        circle(jack.x, socketY, 38)
        if jack.patched {
            fill(Palette.brass.0, Palette.brass.1, Palette.brass.2)
            circle(jack.x, socketY, 20)
            fill(Palette.panelDeep.0, Palette.panelDeep.1, Palette.panelDeep.2)
            circle(jack.x, socketY, 9)
        }

        // 銘。
        textAlign(.center, .baseline)
        fill(Palette.ink.0, Palette.ink.1, Palette.ink.2)
        textSize(15)
        text(jack.title, jack.x, socketY + 56)
        fill(Palette.inkDim.0, Palette.inkDim.1, Palette.inkDim.2)
        textSize(10)
        text(jack.route, jack.x, socketY + 74)
        textSize(12)
        switch (jack.patched, jack.evidence) {
        case (false, _):
            fill(Palette.inkDim.0, Palette.inkDim.1, Palette.inkDim.2)
            text("no patch", jack.x, socketY + 94)
        case (true, .arrival):
            fill(Palette.brass.0, Palette.brass.1, Palette.brass.2)
            text("\(total) frames", jack.x, socketY + 94)
        case (true, .attachment):
            fill(Palette.brass.0, Palette.brass.1, Palette.brass.2)
            text(syphonStatus, jack.x, socketY + 94)
        }
        textAlign(.left, .baseline)
    }

    // MARK: 到着順

    /// 直前フレームの `post()` 到着順。出力フェーズの境目に仕切りを描く。
    private func drawArrivalStrip() {
        let y: Float = 486
        noStroke()
        fill(Palette.panel.0, Palette.panel.1, Palette.panel.2)
        rect(28, y - 26, width - 56, 56, 6)

        fill(Palette.inkDim.0, Palette.inkDim.1, Palette.inkDim.2)
        textSize(11)
        text("ORDER OF post()  —  frame \(log.settledFrame)", 44, y - 8)
        textAlign(.right, .baseline)
        text("[S] Syphon サーバーを止める / 立て直す     [R] サーバー名を変える", width - 44, y - 8)
        textAlign(.left, .baseline)

        var cursor: Float = 44
        var drewDivider = false
        textSize(12)
        for arrival in log.settled {
            // 通常フェーズ → 出力フェーズの境目。
            if arrival.isOutput && !drewDivider {
                drewDivider = true
                stroke(Palette.brass.0, Palette.brass.1, Palette.brass.2)
                strokeWeight(1)
                line(cursor + 4, y + 2, cursor + 4, y + 20)
                noStroke()
                fill(Palette.brass.0, Palette.brass.1, Palette.brass.2)
                textSize(10)
                text("OUTPUT PHASE", cursor + 12, y + 15)
                cursor += 12 + textWidth("OUTPUT PHASE") + 14
                textSize(12)
            }
            let short = shortName(arrival.id)
            let label = "\(arrival.order + 1). \(short)"
            let w = textWidth(label) + 18
            let tone = arrival.isOutput ? Palette.brass : Palette.inkDim
            fill(tone.0, tone.1, tone.2)
            text(label, cursor + 9, y + 15)
            cursor += w
        }
        if log.settled.isEmpty {
            fill(Palette.inkDim.0, Palette.inkDim.1, Palette.inkDim.2)
            text("(まだ 1 フレームも確定していない)", 44, y + 15)
        }
    }

    /// `org.switchboard.tap.aperture` → `tap.aperture`。
    private func shortName(_ id: String) -> String {
        let parts = id.split(separator: ".")
        return parts.count >= 2 ? parts.suffix(2).joined(separator: ".") : id
    }

    // MARK: 記録簿

    /// 交換手の記録簿。決定論的検査の結果がそのまま並ぶ。
    /// **数値の全文は frame.json と標準出力が一次記録**で、ここは要約。
    private func drawLedger() {
        let top: Float = 540
        noStroke()
        fill(Palette.panel.0, Palette.panel.1, Palette.panel.2)
        rect(28, top, width - 56, height - top - 24, 6)

        let failed = checks.filter { !$0.passed }.count
        fill(Palette.brass.0, Palette.brass.1, Palette.brass.2)
        textSize(13)
        text("LOG BOOK  —  setup() で 1 回だけ走る決定論的検査", 46, top + 26)
        textSize(12)
        if failed == 0 {
            fill(Palette.brass.0, Palette.brass.1, Palette.brass.2)
            text("\(checks.count) checks / all PASS", 46, top + 46)
        } else {
            fill(Palette.alarm.0, Palette.alarm.1, Palette.alarm.2)
            text("\(checks.count) checks / \(failed) FAIL", 46, top + 46)
        }

        for (i, check) in checks.enumerated() {
            guard let slot = ledgerSlot(i) else { break }
            let (x, y) = slot

            if check.passed {
                fill(Palette.brass.0, Palette.brass.1, Palette.brass.2)
            } else {
                fill(Palette.alarm.0, Palette.alarm.1, Palette.alarm.2)
            }
            textSize(11)
            text(check.passed ? "PASS" : "FAIL", x, y)
            fill(Palette.ink.0, Palette.ink.1, Palette.ink.2)
            textSize(12)
            text(check.id, x + 40, y)
            fill(Palette.inkDim.0, Palette.inkDim.1, Palette.inkDim.2)
            textSize(10)
            text(clip(check.detail, 62), x + 40, y + 13)
        }
    }

    private func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    /// 記録簿の i 行目の描画位置（2 列組み）。
    private func ledgerSlot(_ i: Int) -> (x: Float, y: Float)? {
        let colX: [Float] = [46, width / 2 + 6]
        let rows = (checks.count + 1) / 2
        let col = i / rows
        guard col < colX.count else { return nil }
        return (colX[col], 540 + 78 + Float(i % rows) * 26)
    }

    /// マウスが乗っている記録簿の行。盤面では実測値を切り詰めているので、
    /// **全文はここで読める**（frame.json / 標準出力と同じ文字列）。
    private func hoveredCheck() -> CheckResult? {
        for (i, check) in checks.enumerated() {
            guard let slot = ledgerSlot(i) else { break }
            let inRow = mouseY > slot.y - 14 && mouseY < slot.y + 17
            let inCol = mouseX > slot.x - 8 && mouseX < slot.x + width / 2 - 40
            if inRow && inCol { return check }
        }
        return nil
    }

    /// ホバー中の行の全文を、カーソルの近くに出す。
    private func drawHoverCard() {
        guard let check = hoveredCheck() else { return }
        let lines = wrap(check.detail, 96)
        let cardW: Float = 720
        let cardH: Float = 34 + Float(lines.count) * 15
        let x = min(max(mouseX - cardW / 2, 24), width - cardW - 24)
        let y = max(mouseY - cardH - 18, 24)

        noStroke()
        fill(12, 10, 9, 242)
        rect(x, y, cardW, cardH, 6)
        stroke(Palette.brassDim.0, Palette.brassDim.1, Palette.brassDim.2)
        strokeWeight(1)
        noFill()
        rect(x, y, cardW, cardH, 6)
        noStroke()

        fill(check.passed ? Palette.brass.0 : Palette.alarm.0,
             check.passed ? Palette.brass.1 : Palette.alarm.1,
             check.passed ? Palette.brass.2 : Palette.alarm.2)
        textSize(12)
        text("\(check.passed ? "PASS" : "FAIL")  \(check.id)", x + 14, y + 22)
        fill(Palette.ink.0, Palette.ink.1, Palette.ink.2)
        textSize(11)
        for (i, line) in lines.enumerated() {
            text(line, x + 14, y + 40 + Float(i) * 15)
        }
    }

    /// 文字数でざっくり折り返す（等幅ではないので目安）。
    private func wrap(_ s: String, _ n: Int) -> [String] {
        var out: [String] = []
        var line = ""
        for word in s.split(separator: " ", omittingEmptySubsequences: false) {
            if line.count + word.count + 1 > n, !line.isEmpty {
                out.append(line)
                line = String(word)
            } else {
                line = line.isEmpty ? String(word) : line + " " + word
            }
        }
        if !line.isEmpty { out.append(line) }
        return out
    }
}
