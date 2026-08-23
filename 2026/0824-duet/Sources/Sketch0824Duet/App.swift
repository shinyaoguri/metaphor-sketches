import Foundation
import metaphor

/// **二重奏**（duet）。
///
/// 一つの渦に置いた声部を、舞台の左右で別の奏者が弾く。左手は Swift の CPU ループ、
/// 右手は MSL のコンピュートカーネル。譜面（`Score`）も初期配置も同じで、右手だけ左右を
/// 映して描くので、**正しければ画面は左右対称**になる。食い違えば対称が崩れて目に見え、
/// 中央の継ぎ目に声部ごとのズレが縦の帯として立つ。
///
/// 幕が上がる前に調弦（`Movement/tuning`）があり、そこで計器（`Instrument`）が
/// GPU 計算の口を一通り叩いた結果を並べる。**FAIL が赤く残る画面も作品の一部**。
@main
final class Sketch0824Duet: Sketch {
    var config: SketchConfig {
        SketchConfig(width: 1280, height: 760, title: "0824-duet")
    }

    private var duet: Duet?
    private var instrument: Instrument?
    private var assay: CountAssay?
    private var startupError: String?

    private var movement: Movement = .tuning
    private var fixedMovement: Movement?
    private var movementStart: Float = 0
    private var barIndex = 0
    private var barrierOn = true
    private var directDraw = true
    private var lastDivergence: Duet.Divergence?
    private var shotsTaken = Set<Int>()
    private var settleDeadline = 240

    private let capacity = 4096

    // MARK: - 舞台の寸法

    /// 舞台の半径 = `Score.bound`（1.55）が枠の内側に収まる倍率。
    /// 枠は 512px 角なので 512/2/1.55 ≒ 165 が上限。少し余裕を取る。
    private var stageScale: Float { 160 }
    private var leftCenter: SIMD2<Float> { SIMD2(320, 316) }
    private var rightCenter: SIMD2<Float> { SIMD2(960, 316) }
    private var seamX: Float { 640 }
    private var bandTop: Float { 596 }

    func setup() {
        frameRate(60)

        let n = Env.int("DUET_N", default: capacity, min: 1, max: capacity)
        do {
            let d = try Duet(host: self, capacity: capacity, count: n)
            duet = d
            instrument = try Instrument(host: self, single: d.single)
            assay = try CountAssay(host: self)
        } catch {
            startupError = String(describing: error)
            Log.line("FAIL setup  \(startupError ?? "")")
        }

        if let name = Env.string("DUET_MOVEMENT"),
           let m = Movement.allCases.first(where: { "\($0)" == name }) {
            fixedMovement = m
            movement = m
        }
        if let dir = Env.string("DUET_FRAMES") {
            beginFrameRecord(directory: dir)
        }
        Log.line("[duet] 声部 \(n) / 固定小節 dt=\(fmt(Score.dt, 5))s / 楽章 "
                 + (fixedMovement.map { "\($0)" } ?? "巡回"))
    }

    // MARK: - 計算フェーズ

    /// **GPU への発注はここでしかできない。** `setup()` や `draw()` から `dispatch` を
    /// 呼んでも、コマンドバッファが無いので黙って何も起きない（`G14`）。
    func compute() {
        guard let duet else { return }

        if let instrument {
            if instrument.stage == 0 {
                instrument.encodeChecks(on: self)
            } else if instrument.stage == 1, instrument.gpuLanded || frameCount > settleDeadline {
                instrument.settleChecks()
            }
        }

        updateMovement()

        let t = Float(duet.step) * Score.dt
        duet.advanceCPU(at: t)
        duet.encodeGPU(
            on: self,
            bars: Bars(
                t: t, dt: Score.dt, count: UInt32(duet.count), flags: 0,
                center: rightCenter, scale: stageScale, mirror: -1, size: 4.2,
                step: duet.step),
            twoPass: movement == .canon,
            barrier: barrierOn)
    }

    /// 楽章を進める。楽章の変わり目では**両者を同じ開幕へ戻す**
    /// （途中で条件を変えると、どちらが崩れたのか分からなくなる）。
    private func updateMovement() {
        guard let duet else { return }
        let now = time

        if let fixed = fixedMovement {
            movement = fixed
        } else if now - movementStart >= movement.seconds {
            movementStart = now
            let next = Movement(rawValue: (movement.rawValue + 1) % Movement.allCases.count) ?? .unison
            movement = next == .tuning ? .unison : next  // 調弦は開幕だけ
            duet.reset()
            barIndex = 0
        }

        switch movement {
        case .oddBars:
            // 2 秒ごとに声部数を境界値へ動かす。末尾が落ちれば絵の縁が欠ける。
            let slot = Int((now - movementStart) / 2.0) % Movement.bars.count
            if slot != barIndex {
                barIndex = slot
                duet.retune(count: Movement.bars[slot])
            }
        case .canon:
            // 2 秒ごとにバリアを入切する。外した側が崩れれば絵に出る。
            barrierOn = Int((now - movementStart) / 2.0) % 2 == 0
        case .copy:
            // 2 秒ごとに右手の描画経路を入れ替える。
            directDraw = Int((now - movementStart) / 2.0) % 2 == 0
        default:
            barrierOn = true
            directDraw = true
        }
    }

    // MARK: - 描画フェーズ

    func draw() {
        background(9, 11, 16)

        if let error = startupError {
            fill(240, 90, 90)
            textSize(18)
            text("二重奏を組み立てられなかった: \(error)", 40, 60)
            return
        }
        guard let duet else { return }

        // 計器の抜け道（G7b）と、描画数の実測（G11）は描画フェーズでしか測れない。
        instrument?.probeLoadPixels(on: self)
        runAssayIfNeeded()

        lastDivergence = duet.divergence()

        drawStage(duet)
        drawSeam(duet)
        drawHeader(duet)
        drawBand(duet)
        if movement == .tuning { drawTuningBoard() }

        publishProbes(duet)
        takeShotIfAsked()
        traceIfAsked(duet)
    }

    private func drawStage(_ duet: Duet) {
        noStroke()

        // 舞台の枠。左右で同じ形なので、対称が崩れたときの目印になる。
        fill(18, 22, 30)
        rect(40, 60, 560, 512, 10)
        rect(680, 60, 560, 512, 10)

        fill(255)
        // 左手（第一奏者）: CPU が解いた声部を CPU の配列から描く。
        circles(duet.cpuMarks(
            center: leftCenter, scale: stageScale, mirror: 1, size: 4.2))

        // 右手（第二奏者）: GPU が書いたバッファ。第 IV 楽章では経路を入れ替える。
        if directDraw {
            circles(duet.markBuffer, count: duet.count)
        } else {
            circles(Array(duet.markBuffer.toArray()[0..<duet.count]))
        }
    }

    /// 継ぎ目。声部ごとのズレを縦に並べる。**ここが灯ったら二人はもう違うものを弾いている。**
    ///
    /// 目盛りは桁（1e-8 が消灯、1e-2 で全灯）。丸めぶんのズレと、譜面が違うときの
    /// ズレは 5 桁も離れるので、線形の目盛りでは両方を同じ帯に載せられない。
    private func drawSeam(_ duet: Duet) {
        guard let d = lastDivergence, d.voices > 0 else { return }
        _ = duet
        noStroke()
        let top: Float = 64
        let height: Float = 504
        let rows = min(d.voices, 168)
        let stepY = height / Float(rows)
        for r in 0..<rows {
            let i = r * d.voices / rows
            let m = d.perVoice[i]
            let decades = m > 0 ? (log10(m) + 8) / 6 : 0
            let lit = min(max(decades, 0), 1)
            fill(26 + lit * 224, 32 + lit * 48, 52 - lit * 12, 210)
            rect(seamX - 8, top + Float(r) * stepY, 16, max(stepY - 1, 1))
        }
    }

    private func drawHeader(_ duet: Duet) {
        fill(226, 232, 240)
        textSize(20)
        text(movement.title, 40, 40)

        textSize(13)
        fill(140, 152, 172)
        text("左手 = CPU (Swift)", 40, 590)
        text("右手 = GPU (MSL compute)" + (directDraw ? " / GPU バッファ直描き" : " / toArray → CPU 配列"),
             680, 590)
        text("声部 \(duet.count)   小節 \(duet.step)", 1050, 40)
    }

    /// 計器帯。数字がそのまま証拠になるように、丸めすぎない。
    private func drawBand(_ duet: Duet) {
        noStroke()
        fill(14, 17, 24)
        rect(0, bandTop, 1280, 164)

        textSize(13)
        if let d = lastDivergence {
            let bad = d.maxAbs > 1e-4
            fill(bad ? 240 : 120, bad ? 110 : 200, bad ? 110 : 150)
            text("食い違い  小節 \(d.step) / \(d.voices) 声部 / 最大 \(sci(d.maxAbs)) / RMS \(sci(d.rms))",
                 40, bandTop + 26)
        } else {
            fill(140, 152, 172)
            text("食い違い  まだ GPU の小節が着地していない", 40, bandTop + 26)
        }

        if let instrument {
            let done = instrument.stage == 2
            fill(done ? (instrument.failures > 0 ? 240 : 120) : 140,
                 done ? (instrument.failures > 0 ? 110 : 200) : 152,
                 done ? (instrument.failures > 0 ? 110 : 150) : 172)
            text("検査  PASS \(instrument.passes) / FAIL \(instrument.failures)"
                 + (done ? "" : "（読み戻し待ち）") + "   詳細は調弦の板と probe check.*",
                 40, bandTop + 48)
        }

        fill(120, 132, 152)
        text("バリア \(barrierOn ? "入" : "切")   刻み \(fmt(Score.dt, 5))s（固定）"
             + "   DUET_MOVEMENT / DUET_N / DUET_TRAP / DUET_SHOTS / DUET_FRAMES / DUET_TRACE",
             40, bandTop + 70)

        if let assay, let line = assay.summary {
            fill(120, 132, 152)
            text(line, 40, bandTop + 92)
        }
    }

    /// 調弦の板。検査の結果をそのまま貼る。
    private func drawTuningBoard() {
        guard let instrument else { return }
        noStroke()
        fill(12, 15, 22, 235)
        rect(40, 60, 1200, 512, 10)

        textSize(15)
        fill(226, 232, 240)
        text("調弦  — GPU 計算の口を一通り叩く", 64, 92)

        textSize(12)
        var y: Float = 122
        for r in instrument.results {
            switch r.verdict {
            case "PASS": fill(120, 205, 150)
            case "FAIL": fill(242, 110, 110)
            case "LOOK": fill(226, 190, 110)
            default: fill(140, 152, 172)
            }
            text("\(r.verdict)  \(r.id)", 64, y)
            fill(160, 172, 190)
            text(String(r.detail.prefix(138)), 244, y)
            y += 21
            if y > 560 { break }
        }
    }

    // MARK: - G11 描画数の実測

    private func runAssayIfNeeded() {
        guard let assay, let instrument, instrument.stage == 2 else { return }
        assay.stepOnce(on: self, instrument: instrument)
    }

    // MARK: - 観測の口

    private func publishProbes(_ duet: Duet) {
        probe("movement", "\(movement)")
        probe("voices", duet.count)
        probe("step", Int(duet.step))
        probe("barrier", barrierOn)
        probe("directDraw", directDraw)
        if let d = lastDivergence {
            probe("divergence.max", d.maxAbs)
            probe("divergence.rms", d.rms)
            probe("divergence.step", Int(d.step))
        }
        instrument?.publish(to: self)
    }

    private func takeShotIfAsked() {
        guard Env.flag("DUET_SHOTS"), !shotsTaken.contains(movement.rawValue) else { return }
        // 楽章に入って 3 秒後に 1 枚だけ。saveFrame は ~/Desktop を無条件に前置する。
        guard time - movementStart > 3 else { return }
        shotsTaken.insert(movement.rawValue)
        saveFrame("duet-\(movement).png")
        Log.line("[duet] 撮影 duet-\(movement).png（~/Desktop へ）")
    }

    private func traceIfAsked(_ duet: Duet) {
        guard Env.flag("DUET_TRACE"), frameCount % 60 == 0 else { return }
        if let d = lastDivergence {
            Log.line("[duet] \(movement) 小節 \(d.step) 声部 \(d.voices) "
                     + "最大 \(sci(d.maxAbs)) RMS \(sci(d.rms)) バリア \(barrierOn ? "入" : "切")")
        } else {
            Log.line("[duet] \(movement) 小節 \(duet.step) 着地待ち")
        }
    }
}

// MARK: - G11 の測り方

/// `circles(_:count:)` に渡した `count` が**実際に何個描くか**は、
/// 絵を読み戻すまで分からない。既知の位置へ 5 個置いて、点いた数を数える。
@MainActor
final class CountAssay {
    private let buffer: GPUBuffer<CircleInstance>
    private let spots: [SIMD2<Float>]
    private let variants: [Int?] = [nil, 3, 99, 0, -5]
    private var index = 0
    private var measured: [(Int?, Int)] = []
    private(set) var summary: String?

    init(host: some Sketch) throws {
        let y: Float = 748
        spots = (0..<5).map { SIMD2(34 + Float($0) * 26, y) }
        let marks = spots.map {
            CircleInstance(position: $0, diameter: 14, color: SIMD4<Float>(1, 1, 1, 1))
        }
        guard let b = host.createBuffer(marks) else { throw DuetError.bufferAllocationFailed }
        buffer = b
    }

    /// 1 フレームにつき 1 通りだけ試す（`loadPixels()` はレンダーパスを割るので、
    /// 1 フレームに何度も呼ぶと絵そのものが変わる）。
    func stepOnce(on host: some Sketch, instrument: Instrument) {
        guard index < variants.count else { return }
        let variant = variants[index]
        index += 1

        host.noStroke()
        host.fill(255)
        host.circles(buffer, count: variant)
        host.loadPixels()

        var lit = 0
        for s in spots {
            let c = host.get(Int(s.x), Int(s.y))
            if c.r + c.g + c.b > 0.9 { lit += 1 }
        }
        measured.append((variant, lit))

        if index == variants.count {
            let text = measured.map { "count=\($0.0.map(String.init) ?? "省略")→\($0.1)個" }
                .joined(separator: " / ")
            summary = "G11 描画数の実測（置いた 5 個のうち点いた数）: \(text)"
            let ok = measured.allSatisfy { pair in
                let expected = min(max(pair.0 ?? 5, 0), 5)
                return pair.1 == expected
            }
            instrument.recordExternal(
                "G11.circlesCount", ok ? "PASS" : "FAIL",
                "\(text) / 期待は min(max(count, 0), バッファ長=5) にクランプ")
        }
    }
}
