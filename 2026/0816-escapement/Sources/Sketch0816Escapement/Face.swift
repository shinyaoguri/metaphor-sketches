import Foundation
import metaphor

// 文字盤と機構の描画。
//
// 見えているものは全部「もっとも基本的な API」で組んである — 角度は `PI` / `TAU` /
// `radians`、位置は `map` / `lerp` / `constrain`、機構の運動は `sine01` / `square` /
// `triangle` / `sawtooth`、地板の梨地は seed 固定の `random` / `noise`、
// 外周の飾りはイージング 30 本そのもの。

/// 表示する面。TAB で巡回する。
enum Plate: Int, CaseIterable {
    case dial        // 時計（既定）
    case regulator   // 緩急針の板 — イージング 30 本を図として広げる
    case oscillogram // 振動の板 — 波形 5 本を並べる

    var title: String {
        switch self {
        case .dial: return "DIAL"
        case .regulator: return "REGULATOR — 30 easing curves"
        case .oscillogram: return "OSCILLOGRAM — 5 waveforms"
        }
    }

    var next: Plate { Plate(rawValue: (rawValue + 1) % Plate.allCases.count)! }
}

/// 配色。地板は暗く、真鍮と鋼で描く。
enum Ink {
    static let plate = Color(hex: 0x0A0D12)
    static let plateEdge = Color(hex: 0x161C26)
    static let brass = Color(hex: 0xC9A227)
    static let brassDim = Color(hex: 0x6E5A18)
    static let steel = Color(hex: 0x8FA3B0)
    static let steelDim = Color(hex: 0x44525C)
    static let ruby = Color(hex: 0xC0392B)
    static let ink = Color(hex: 0xE8E4D9)
}

@MainActor
enum Face {
    // MARK: - 地板の梨地

    /// seed 固定で撒く粒。`randomSeed` が効いていれば**起動するたび同じ絵**になる。
    static func grain(seed: UInt64, count: Int, width: Float, height: Float) -> [(Float, Float, Float)] {
        randomSeed(seed)
        return (0..<count).map { _ in
            (random(width), random(height), random(0.4, 1.8))
        }
    }

    static func drawGrain(_ s: Sketch0816Escapement, _ grains: [(Float, Float, Float)]) {
        s.noStroke()
        for (x, y, r) in grains {
            // 明度をノイズで揺らす。同じ座標なら同じ値なので、絵は静止したまま
            let n = noise(x * 0.004, y * 0.004)
            s.fill(Ink.plateEdge.r * 255 * (0.6 + n), Ink.plateEdge.g * 255 * (0.6 + n), Ink.plateEdge.b * 255 * (0.6 + n))
            s.circle(x, y, r)
        }
    }

    // MARK: - 文字盤

    /// 目盛りと数字。角度は Constants と `radians` だけで出す。
    static func drawDial(_ s: Sketch0816Escapement, cx: Float, cy: Float, r: Float) {
        s.push()
        s.translate(cx, cy)

        // 外周の 2 本のリング
        s.noFill()
        s.stroke(Ink.steelDim)
        s.strokeWeight(2)
        s.circle(0, 0, r * 2)
        s.stroke(Ink.brassDim)
        s.strokeWeight(1)
        s.circle(0, 0, r * 2 - 26)

        // 60 分目盛り。12 の倍数だけ長く太くする
        for i in 0..<60 {
            let angle = TAU * Float(i) / 60
            let isHour = i % 5 == 0
            let inner = isHour ? r - 34 : r - 20
            s.stroke(isHour ? Ink.brass : Ink.steelDim)
            s.strokeWeight(isHour ? 3 : 1)
            // 12 時を上に置くので -HALF_PI ぶん回す
            let a = angle - HALF_PI
            s.line(cos(a) * inner, sin(a) * inner, cos(a) * (r - 8), sin(a) * (r - 8))
        }

        // 12 個の数字
        s.noStroke()
        s.fill(Ink.ink)
        s.textSize(20)
        s.textAlign(.center, .center)
        for i in 1...12 {
            let a = TAU * Float(i) / 12 - HALF_PI
            s.text("\(i)", cos(a) * (r - 58), sin(a) * (r - 58))
        }
        s.pop()
    }

    /// 針。秒針だけは脱進機に合わせて**カチリと飛ぶ**（連続で滑らせない）。
    static func drawHands(_ s: Sketch0816Escapement, cx: Float, cy: Float, r: Float, clock: ClockReading) {
        s.push()
        s.translate(cx, cy)

        func hand(_ turn: Float, length: Float, weight: Float, color: Color, tail: Float) {
            let a = TAU * turn - HALF_PI
            s.stroke(color)
            s.strokeWeight(weight)
            s.line(-cos(a) * tail, -sin(a) * tail, cos(a) * length, sin(a) * length)
        }

        hand(clock.hourTurn, length: r * 0.52, weight: 7, color: Ink.ink, tail: 22)
        hand(clock.minuteTurn, length: r * 0.76, weight: 4, color: Ink.ink, tail: 30)
        hand(clock.secondTurn, length: r * 0.84, weight: 1.5, color: Ink.ruby, tail: 42)

        // 中心の帽
        s.noStroke()
        s.fill(Ink.brass)
        s.circle(0, 0, 14)
        s.fill(Ink.plate)
        s.circle(0, 0, 5)
        s.pop()
    }

    // MARK: - 機構（スケルトン文字盤から覗く）

    /// ガンギ車。1 秒に 1 歯ぶんだけ回る＝脱進機の離散化そのもの。
    static func drawEscapeWheel(_ s: Sketch0816Escapement, cx: Float, cy: Float, r: Float, tick: Float, teeth: Int) {
        s.push()
        s.translate(cx, cy)
        // tick は「何秒目か」。歯 1 枚ぶんずつ回す
        s.rotate(TAU * tick / Float(teeth))

        s.noFill()
        s.stroke(Ink.brassDim)
        s.strokeWeight(2)
        s.circle(0, 0, r * 2)
        s.circle(0, 0, r * 0.5)

        // のこぎり歯
        s.stroke(Ink.brass)
        s.strokeWeight(2)
        for i in 0..<teeth {
            let a = TAU * Float(i) / Float(teeth)
            let b = a + TAU / Float(teeth) * 0.55
            s.line(cos(a) * r * 0.5, sin(a) * r * 0.5, cos(a) * r, sin(a) * r)
            s.line(cos(a) * r, sin(a) * r, cos(b) * r * 0.5, sin(b) * r * 0.5)
        }
        s.pop()
    }

    /// アンクル。矩形波を少しなまらせて、左右の爪へ交互に落とす。
    static func drawAnchor(_ s: Sketch0816Escapement, cx: Float, cy: Float, span: Float, phase: Float) {
        // square() の 0/1 を easeOutBack で軟らかくし、実際の跳ね返りに見せる
        let swing = lerp(Float(-1), Float(1), phase)
        s.push()
        s.translate(cx, cy)
        s.rotate(radians(14) * swing)

        s.stroke(Ink.steel)
        s.strokeWeight(5)
        s.noFill()
        s.line(-span, 0, span, 0)
        s.line(0, 0, 0, span * 0.9)
        s.strokeWeight(3)
        s.line(-span, 0, -span, 16)
        s.line(span, 0, span, 16)

        s.noStroke()
        s.fill(Ink.ruby)
        s.circle(-span, 12, 9)
        s.circle(span, 12, 9)
        s.fill(Ink.brass)
        s.circle(0, 0, 10)
        s.pop()
    }

    /// てんぷ。正弦で連続的に振れる（アンクルの離散との対比が主題）。
    static func drawBalance(_ s: Sketch0816Escapement, cx: Float, cy: Float, r: Float, turn: Float) {
        s.push()
        s.translate(cx, cy)
        s.rotate(turn)

        s.noFill()
        s.stroke(Ink.brass)
        s.strokeWeight(3)
        s.circle(0, 0, r * 2)
        s.strokeWeight(2)
        s.stroke(Ink.brassDim)
        for i in 0..<4 {
            let a = TAU * Float(i) / 4
            s.line(0, 0, cos(a) * r, sin(a) * r)
        }
        s.noStroke()
        s.fill(Ink.steel)
        s.circle(0, 0, 9)
        s.pop()
    }

    /// ゼンマイの渦。Catmull-Rom で control point を繋ぐ（curvePoint の実地の使い道）。
    static func drawMainspring(_ s: Sketch0816Escapement, cx: Float, cy: Float, r: Float, wind: Float) {
        s.push()
        s.translate(cx, cy)
        s.noFill()
        s.stroke(Ink.steelDim)
        s.strokeWeight(2)

        // 巻き上げ量で内側の巻き数が変わる。smoothstep でなめらかに効かせる
        let turns = lerp(Float(2.4), Float(4.2), smoothstep(0, 1, wind))
        s.beginShape(.polygon)
        let steps = 360
        for i in 0...steps {
            let t = Float(i) / Float(steps)
            let a = TAU * turns * t
            let rad = lerp(r * 0.16, r, easeOutSine(t))
            s.vertex(cos(a) * rad, sin(a) * rad)
        }
        s.endShape(.open)
        s.pop()
    }

    // MARK: - 外周の飾り = イージング 30 本

    /// 30 本のイージングを 12° ずつの目盛りとして外周の帯に並べる。装飾でありながらそのまま図。
    ///
    /// Back / Elastic は定義上 [0,1] を出るので、帯の外へ少しだけはみ出す（そこが見どころ）。
    /// ただし Elastic は ±0.37 まで振れて帯が読めなくなるので、はみ出しは ±0.18 で頭打ちにする。
    static func drawEasingRing(_ s: Sketch0816Escapement, cx: Float, cy: Float, inner: Float, outer: Float, highlight: Int) {
        let curves = Instrument.easingFamilies.flatMap { (name, fin, fout, finout) in
            [("\(name) In", fin), ("\(name) Out", fout), ("\(name) InOut", finout)]
        }
        s.push()
        s.translate(cx, cy)
        s.noFill()

        // 帯の内側・外側の縁
        s.stroke(Ink.plateEdge)
        s.strokeWeight(1)
        s.circle(0, 0, inner * 2)
        s.circle(0, 0, outer * 2)

        for (index, entry) in curves.enumerated() {
            let (_, f) = entry
            let a0 = TAU * Float(index) / Float(curves.count) - HALF_PI
            let a1 = TAU * Float(index + 1) / Float(curves.count) - HALF_PI
            let lit = index == highlight
            s.stroke(lit ? Ink.brass : Ink.steelDim)
            s.strokeWeight(lit ? 2.4 : 1.1)
            s.beginShape(.polygon)
            for i in 0...20 {
                let t = Float(i) / 20
                let a = lerp(a0, a1, t)
                let rad = lerp(inner, outer, constrain(f(t), -0.18, 1.18))
                s.vertex(cos(a) * rad, sin(a) * rad)
            }
            s.endShape(.open)

            // 区切り
            s.stroke(Ink.plateEdge)
            s.strokeWeight(1)
            s.line(cos(a0) * inner, sin(a0) * inner, cos(a0) * outer, sin(a0) * outer)
        }
        s.pop()
    }

    // MARK: - 面 2: 緩急針の板

    static func drawRegulator(_ s: Sketch0816Escapement, w: Float, h: Float, phase: Float) {
        let curves = Instrument.easingFamilies.flatMap { (name, fin, fout, finout) in
            [("\(name)In", fin), ("\(name)Out", fout), ("\(name)InOut", finout)]
        }
        let cols = 6
        let rows = 5
        let cellW = w / Float(cols)
        // 上は見出し、下はキー説明のぶんを空ける
        let cellH = (h - 116) / Float(rows)

        s.textSize(11)
        s.textAlign(.left, .top)
        for (index, entry) in curves.enumerated() {
            let (name, f) = entry
            let col = index % cols
            let row = index / cols
            let x0 = Float(col) * cellW + 26
            let y0 = 60 + Float(row) * cellH + 14
            let cw = cellW - 52
            let ch = cellH - 40

            s.noStroke()
            s.fill(Ink.steelDim)
            s.text(name, x0, y0 - 14)

            // 枠
            s.noFill()
            s.stroke(Ink.plateEdge)
            s.strokeWeight(1)
            s.rect(x0, y0, cw, ch)

            // 曲線。オーバーシュートが枠を出るのは定義どおりなので隠さない
            s.stroke(Ink.brass)
            s.strokeWeight(1.6)
            s.beginShape(.polygon)
            for i in 0...48 {
                let t = Float(i) / 48
                s.vertex(x0 + cw * t, y0 + ch * (1 - f(t)))
            }
            s.endShape(.open)

            // いま何 t を通っているかの点（時計の秒と同期して 1 秒で 1 往復）
            let t = triangle(Double(phase), frequency: 1)
            s.noStroke()
            s.fill(Ink.ruby)
            s.circle(x0 + cw * t, y0 + ch * (1 - f(t)), 5)
        }
    }

    // MARK: - 面 3: 振動の板

    static func drawOscillogram(_ s: Sketch0816Escapement, w: Float, h: Float, t: Double) {
        let waves: [(String, (Double) -> Float)] = [
            ("sine01", { sine01($0, frequency: 1) }),
            ("cosine01", { cosine01($0, frequency: 1) }),
            ("triangle", { triangle($0, frequency: 1) }),
            ("sawtooth", { sawtooth($0, frequency: 1) }),
            ("square (duty 0.5)", { square($0, frequency: 1, duty: 0.5) }),
        ]
        let laneH = (h - 90) / Float(waves.count)

        s.textSize(13)
        s.textAlign(.left, .center)
        for (index, entry) in waves.enumerated() {
            let (name, f) = entry
            let y0 = 64 + Float(index) * laneH
            let ch = laneH - 26
            let x0: Float = 150
            let cw = w - x0 - 60

            s.noStroke()
            s.fill(Ink.steel)
            s.text(name, 40, y0 + ch / 2)

            // 目盛り（0 / 0.5 / 1）
            s.stroke(Ink.plateEdge)
            s.strokeWeight(1)
            for level in [Float(0), 0.5, 1] {
                s.line(x0, y0 + ch * (1 - level), x0 + cw, y0 + ch * (1 - level))
            }

            // 直近 3 周期ぶんを流す
            s.stroke(index % 2 == 0 ? Ink.brass : Ink.steel)
            s.strokeWeight(1.8)
            s.noFill()
            s.beginShape(.polygon)
            for i in 0...480 {
                let u = Double(i) / 480
                s.vertex(x0 + cw * Float(u), y0 + ch * (1 - f(t - 3 + u * 3)))
            }
            s.endShape(.open)

            // 現在値
            s.noStroke()
            s.fill(Ink.ruby)
            s.circle(x0 + cw, y0 + ch * (1 - f(t)), 6)
        }
    }
}

/// 文字盤が指すべき値。実時刻と、りゅうずで足したオフセットから決まる。
struct ClockReading {
    let hourTurn: Float      // 0…1（12 時間で 1 周）
    let minuteTurn: Float
    let secondTurn: Float
    let label: String
    let tickIndex: Float     // 何秒目か（脱進機の歯送りに使う）
}
