import Foundation
import metaphor

/// 脱進機 — 連続する動力を、正確に刻まれた離散のステップへ変える時計の心臓部。
///
/// metaphor のフレームループがやっていることと同じなので、これを主題にした。見えている
/// 部品は全部「もっとも基本的な API」で組んである（角度は `Constants` と `radians`、
/// 位置は `map` / `lerp`、運動は波形、地板は seed 固定の `random` / `noise`、外周の飾りは
/// イージング 30 本そのもの）。裏では `Instrument` / `Runtime` が同じ API を数式と突き合わせ、
/// 判定を `probe("check.<ID>")` と標準出力へ出す。
@main
final class Sketch0816Escapement: Sketch {
    // MARK: - 設定

    var config: SketchConfig {
        var plugins: [PluginFactory] = []
        // 入力注入プラグインは headless（METAPHOR_VIEWER=1）でしか自動登録されない。
        // ここで明示登録すると素の `swift run`（窓あり）でも stdin から動かせるはず、
        // という仮説の検証も兼ねている（CONTRACT.md 契約点 3）。
        if ProcessInfo.processInfo.environment["ESCAPEMENT_INJECT"] == "1" {
            plugins.append(PluginFactory { InputInjectionPlugin() })
        }
        return SketchConfig(
            width: 1280, height: 720,
            title: "0816-escapement",
            plugins: plugins
        )
    }

    // MARK: - 機構の状態

    /// りゅうずで送った時刻のオフセット（秒）。
    private var offsetSeconds: Float = 0
    /// ゼンマイの巻き上げ量 0…1。渦の巻き数とてんぷの振り角に効く。
    private var wind: Float = 0.35
    /// 表示中の面。
    private var plate: Plate = .dial
    /// 地板の梨地（seed 固定なので毎回同じ絵）。
    private var grains: [(Float, Float, Float)] = []

    private let instrument = Runtime()
    private var checks: [Verdict] = []
    private var checkSummary = "…"

    // MARK: - 観測の口

    private let shots = ProcessInfo.processInfo.environment["ESCAPEMENT_SHOTS"] == "1"
    private let framesDir = ProcessInfo.processInfo.environment["ESCAPEMENT_FRAMES"]
    private let trap = ProcessInfo.processInfo.environment["ESCAPEMENT_TRAP"]
    private var shotsTaken = 0

    // MARK: - ライフサイクル

    func setup() {
        frameRate(60)
        textFont("Helvetica Neue")

        // 頼まれたときだけ、落ちうる呼び出しを踏みにいく。
        // 検査に常時含めると作品が起動しなくなるので、この口を分けている。
        if let trap { runTrap(trap) }

        // 決定論的な検査（M / E / W / R / C 系）。ここで乱数とノイズの seed を散らかすので、
        // 作品が使う seed はこの後で撒き直す。
        checks = Instrument.runAll()
        for v in checks { print(v.line) }
        fflush(stdout)

        grains = Face.grain(seed: 20260816, count: 1400, width: width, height: height)
        randomSeed(20260816)
        noiseSeed(20260816)
        noiseDetail(octaves: 4, falloff: 0.5)

        instrument.allVerdicts = { [weak self] in self?.allVerdicts() ?? [] }
        instrument.scheduleLoopChecks(self)
    }

    func draw() {
        instrument.observe(self)
        if frameCount == 3 { instrument.noteDeltaHead(time) }

        background(Ink.plate)

        switch plate {
        case .dial: drawDialPlate()
        case .regulator: Face.drawRegulator(self, w: width, h: height, phase: time)
        case .oscillogram: Face.drawOscillogram(self, w: width, h: height, t: Double(time))
        }

        drawChrome()
        publishProbes()
        handleShots()
        handleFrames()
    }

    // MARK: - 面 1: 時計

    private func drawDialPlate() {
        let cx = width / 2
        let cy = height / 2
        let r: Float = 250

        Face.drawGrain(self, grains)

        let clock = reading()

        // 外周の帯 = イージング 30 本。秒が進むごとに 1 本ずつ灯る
        Face.drawEasingRing(self, cx: cx, cy: cy, inner: r + 16, outer: r + 46,
                            highlight: Int(clock.tickIndex.truncatingRemainder(dividingBy: 30)))

        // スケルトン文字盤から覗く機構
        Face.drawMainspring(self, cx: cx - 120, cy: cy + 6, r: 98, wind: wind)
        Face.drawEscapeWheel(self, cx: cx + 106, cy: cy - 68, r: 58, tick: clock.tickIndex, teeth: 15)
        // アンクルは矩形波。1 秒ごとに左右へ落ちる（= 離散）。
        // 波形の `square(_:frequency:duty:)` は Sketch の中では描画メソッドの
        // `square(_:_:_:)` に食われるので、モジュール修飾が要る
        Face.drawAnchor(self, cx: cx + 106, cy: cy + 6, span: 40,
                        phase: MetaphorCore.square(Double(clock.tickIndex), frequency: 0.5, duty: 0.5))
        // てんぷは正弦。振り角は巻き上げ量で決まる（= 連続）
        Face.drawBalance(self, cx: cx + 92, cy: cy + 116, r: 50,
                         turn: radians(lerp(20, 150, wind)) * (sine01(Double(time), frequency: 2.5) * 2 - 1))

        Face.drawDial(self, cx: cx, cy: cy, r: r)
        Face.drawHands(self, cx: cx, cy: cy, r: r, clock: clock)

        // 時刻の表示。機構と針を避けて 12 時の下へ置く
        noStroke()
        fill(Ink.ink)
        textSize(24)
        textAlign(.center, .center)
        text(clock.label, cx, cy - 126)
    }

    /// 実時刻 + りゅうずのオフセットから針の位置を出す。
    private func reading() -> ClockReading {
        // 実時刻を「今日の 0 時からの秒」に直し、オフセットを足す
        let base = Float(hour() * 3600 + minute() * 60 + second())
        // millis() の下 3 桁でミリ秒ぶんを補う（second() は整数までしか無い）
        let fraction = Float(millis() % 1000) / 1000
        var t = base + fraction + offsetSeconds
        // 12 時間で 1 周。負のオフセットでも折り返すように正規化する
        let half: Float = 12 * 3600
        t = t.truncatingRemainder(dividingBy: half)
        if t < 0 { t += half }

        // 秒針は脱進機に合わせて「カチリ」と飛ぶので、切り捨てた秒を使う
        let ticks = (t).rounded(.down)
        let shownSeconds = Int(ticks) % 60
        let shownMinutes = (Int(ticks) / 60) % 60
        let shownHours = (Int(ticks) / 3600) % 12

        return ClockReading(
            hourTurn: t / half,
            minuteTurn: t.truncatingRemainder(dividingBy: 3600) / 3600,
            secondTurn: Float(shownSeconds) / 60,
            label: String(format: "%02d:%02d:%02d", shownHours == 0 ? 12 : shownHours, shownMinutes, shownSeconds),
            tickIndex: ticks
        )
    }

    // MARK: - 縁の情報

    private func drawChrome() {
        noStroke()
        textAlign(.left, .top)

        textSize(14)
        fill(Ink.steel)
        text("0816-escapement — \(plate.title)", 26, 22)

        textSize(11)
        fill(Ink.steelDim)
        let keys = "SPACE 止/動   ENTER 1 コマ   TAB 面   ← → 時刻   ↑ ↓ 巻き上げ   ESC 戻す"
        text(keys, 26, height - 34)

        // 自己検査の要約。FAIL があれば赤で残す（見た目そのものが検査盤になる）
        let failed = allVerdicts().filter { !$0.passed }
        textAlign(.right, .top)
        textSize(12)
        if failed.isEmpty {
            fill(Ink.steelDim)
        } else {
            fill(Ink.ruby)
        }
        text(checkSummary, width - 26, 24)
        if !failed.isEmpty {
            textSize(11)
            for (i, v) in failed.prefix(6).enumerated() {
                text(v.id, width - 26, 44 + Float(i) * 15)
            }
        }

        // 止まっているあいだは、それが分かるように印を出す
        if !isLooping {
            textAlign(.center, .center)
            textSize(15)
            fill(Ink.ruby)
            text("STOPPED — ENTER で 1 コマ / SPACE で再開", width / 2, height - 62)
        }
    }

    private func allVerdicts() -> [Verdict] { checks + instrument.verdicts }

    // MARK: - probe

    private func publishProbes() {
        let all = allVerdicts()
        // 判定はフレームごとに増えるので、増えたぶんだけ載せ直す
        for v in all {
            probe("check.\(v.id)", v.line)
        }
        let pass = all.filter(\.passed).count
        checkSummary = "self-check \(pass)/\(all.count) PASS"
        probe("check.summary.total", all.count)
        probe("check.summary.pass", pass)
        probe("plate", plate.title)
        probe("wind", wind)
        probe("offsetSeconds", offsetSeconds)
        probe("isLooping", isLooping)
    }

    // MARK: - 面ごとの書き出し

    /// `ESCAPEMENT_SHOTS=1` のとき 3 面を巡って 1 枚ずつ撮る。
    /// `saveFrame(_:)` は渡した名前に無条件で `~/Desktop/` を前置する（metaphor#757、
    /// main では修正済みだが v0.9.0 では未リリース）ので、置き場は probe.sh 側で直す。
    private func handleShots() {
        guard shots, frameCount > 200 else { return }
        let every = 90
        guard (frameCount - 200) % every == 0, shotsTaken < Plate.allCases.count else { return }
        let name = "escapement-\(plate.title.split(separator: " ").first!.lowercased()).png"
        saveFrame(name)
        print("[shot] \(name)")
        fflush(stdout)
        shotsTaken += 1
        plate = plate.next
    }

    /// GIF 用の連番書き出し。自己検査（L 系がループを止める）が終わってから始めないと、
    /// 止まっている数秒がそのまま GIF に写る。
    /// `beginFrameRecord(directory:)` は絶対パスを尊重する（`saveFrame(_:)` は尊重しない → metaphor#757）。
    private func handleFrames() {
        guard let framesDir else { return }
        if frameCount == 600 {
            beginFrameRecord(directory: framesDir, pattern: "escapement_%05d.png")
            print("[frames] \(framesDir) へ記録開始")
            fflush(stdout)
        }
        if frameCount == 900 {
            endFrameRecord()
            print("[frames] 記録終了（300 枚 = 5 秒）")
            fflush(stdout)
        }
    }

    // MARK: - 入力

    func mouseMoved() { instrument.record("mouseMoved", self) }

    func mousePressed() { instrument.record("mousePressed", self) }

    func mouseReleased() { instrument.record("mouseReleased", self) }

    /// りゅうずを回す。横に引いた量がそのまま時刻送り、縦が巻き上げ。
    func mouseDragged() {
        instrument.record("mouseDragged", self)
        offsetSeconds += (mouseX - pmouseX) * 20
        wind = constrain(wind - (mouseY - pmouseY) * 0.004, 0, 1)
    }

    func mouseScrolled() {
        instrument.record("scroll", self)
        offsetSeconds += scrollY * 60
    }

    func keyPressed() {
        instrument.record("keyPressed", self)
        guard let code = keyCode else { return }
        switch code {
        case SPACE:
            // 止める / 動かす。noLoop() は draw() の外から呼ぶ（ここは入力コールバック）
            if isLooping { noLoop() } else { loop() }
        case metaphor.RETURN, ENTER:
            redraw()
        case TAB:
            plate = plate.next
            if !isLooping { redraw() }
        case LEFT: offsetSeconds -= 60
        case RIGHT: offsetSeconds += 60
        case UP: wind = constrain(wind + 0.08, 0, 1)
        case DOWN: wind = constrain(wind - 0.08, 0, 1)
        case ESCAPE:
            offsetSeconds = 0
            wind = 0.35
        default: break
        }
        if !isLooping && code != SPACE { redraw() }
    }

    func keyReleased() { instrument.record("keyReleased", self) }

    // MARK: - リロードを跨ぐ状態

    /// 巻いた分と面はリロードを跨いで残す（`METAPHOR_STATE=1` / `metaphor watch` 下で有効）。
    func saveState() -> Data? {
        encodeState(Persisted(offsetSeconds: offsetSeconds, wind: wind, plate: plate.rawValue))
    }

    func restoreState(_ data: Data) {
        guard let p: Persisted = decodeState(data) else { return }
        offsetSeconds = p.offsetSeconds
        wind = p.wind
        plate = Plate(rawValue: p.plate) ?? .dial
        print("[state] 復元 offset=\(p.offsetSeconds)s wind=\(p.wind) plate=\(plate.title)")
        fflush(stdout)
    }

    struct Persisted: Codable {
        let offsetSeconds: Float
        let wind: Float
        let plate: Int
    }

    // MARK: - 落ちうる呼び出し（頼まれたときだけ）

    /// 検査に常時含めると作品が起動しなくなる呼び出しを、`ESCAPEMENT_TRAP=<名前>` で
    /// 明示的に踏む。落ちるかどうか自体が観測対象。
    private func runTrap(_ name: String) {
        print("[trap] \(name) を踏む")
        fflush(stdout)
        switch name {
        case "frameRateZero":
            frameRate(0)
        case "frameRateNegative":
            frameRate(-1)
        case "noiseOctavesZero":
            noiseDetail(octaves: 0, falloff: 0.5)
            print("[trap] noise(0.5)=\(noise(0.5))")
        case "noiseOctavesNegative":
            noiseDetail(octaves: -3, falloff: 0.5)
            print("[trap] noise(0.5)=\(noise(0.5))")
        case "graphicsZero":
            // Optional を返す = 失敗しうる、という宣言なので nil が素直な期待。
            // v0.9.0 では Metal のアサーションでプロセスごと落ちる（metaphor#798）
            let g = createGraphics(0, 0)
            print("[trap] createGraphics(0,0)=\(g == nil ? "nil" : "非 nil")")
        case "graphicsNegative":
            let g = createGraphics(-8, 16)
            print("[trap] createGraphics(-8,16)=\(g == nil ? "nil" : "非 nil")")
        case "imageZero":
            let i = createImage(0, 0)
            print("[trap] createImage(0,0)=\(i == nil ? "nil" : "非 nil")")
        case "graphics3DZero":
            let g = createGraphics3D(0, 0)
            print("[trap] createGraphics3D(0,0)=\(g == nil ? "nil" : "非 nil")")
        case "textSizeZero":
            textSize(0)
            print("[trap] textWidth(\"abc\")=\(textWidth("abc"))")
        case "curveDetailZero":
            curveDetail(0)
        case "easeNaN":
            print("[trap] easeInOutCubic(nan)=\(easeInOutCubic(Float.nan))")
        default:
            print("[trap] 未知の名前。frameRateZero / frameRateNegative / noiseOctavesZero / noiseOctavesNegative / graphicsZero / graphicsNegative / graphics3DZero / imageZero / textSizeZero / curveDetailZero / easeNaN")
        }
        fflush(stdout)
    }
}
