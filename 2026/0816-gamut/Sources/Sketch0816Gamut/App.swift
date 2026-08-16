import Foundation
import metaphor

// 0816-gamut — 光と絵の具
//
// 同じ 3 原色が、光として重なれば白へ、絵の具として重なれば黒へ向かう。
// 両方の卓に同じ「薄め」つまみ（α）が効く — はずだが、合成の仕方によっては効かない。
//
// 起動直後の 2 フレームで決定論的な自己検査を回し、結果を frame.json の
// `custom`（`check.<ID>`）と標準出力へ出してから作品に入る。

@main
final class Sketch0816Gamut: Sketch {
    var config: SketchConfig {
        SketchConfig(width: 1280, height: 720, title: "0816-gamut")
    }

    // MARK: - 検査の状態

    private(set) var verdicts: [Verdict] = []
    private var swatch: Swatch?
    /// 0 = オフスクリーン検査 + メイン検査、1 = フレーム跨ぎの検査、2 以降 = 作品。
    private var phase = 0
    /// フレーム跨ぎ検査で、パッチを描く前にその位置に写っていた色。
    private var leakBackdrop: RGBA8?

    // MARK: - 作品の状態

    enum ViewMode: Int, CaseIterable {
        case compare, light, pigment, verdicts
        var next: ViewMode { ViewMode(rawValue: (rawValue + 1) % ViewMode.allCases.count)! }
        var title: String {
            switch self {
            case .compare: return "対比 — 同じ α を両方の卓へ"
            case .light: return "光の卓"
            case .pigment: return "絵の具の卓"
            case .verdicts: return "自己検査"
            }
        }
    }

    private var view: ViewMode = .compare
    private var modeIndex = 0
    /// 「薄め」つまみ。両方の卓に同じ値が効く。
    private var alpha: Float = 1.0
    /// 3 円の開き（マウスの縦ドラッグ）。
    private var spread: Float = 1.0
    private var spinning = true
    private var spin: Float = 0

    /// 実測の帯。毎フレーム `loadPixels()` すると重いので間引いて更新する。
    private var samples: [(area: String, label: String, color: RGBA8)] = []

    // MARK: - 観測の口（MCP が使えないときはこれで足りる）

    private let shotMode = ProcessInfo.processInfo.environment["GAMUT_SHOTS"] == "1"
    private let traceMode = ProcessInfo.processInfo.environment["GAMUT_TRACE"] == "1"
    private let framesDir = ProcessInfo.processInfo.environment["GAMUT_FRAMES"]
    /// `GAMUT_DEMO=1` で α を自動で往復させる（GIF 用。薄めたときの非対称が主題なので、
    /// 静止画 1 枚では伝わらない）。
    private let demoMode = ProcessInfo.processInfo.environment["GAMUT_DEMO"] == "1"
    /// `GAMUT_MODE=0|1|2` で合成モードを固定する。
    private let forcedMode = ProcessInfo.processInfo.environment["GAMUT_MODE"].flatMap { Int($0) }
    private var shotsTaken = 0
    private var recording = false

    // MARK: - 領域

    private var contentTop: Float { 88 }
    private var contentBottom: Float { height - 148 }
    private var fullArea: Patch {
        Patch(x: 150, y: contentTop, w: width - 300, h: contentBottom - contentTop)
    }
    private var leftArea: Patch {
        Patch(x: 28, y: contentTop, w: (width - 84) / 2, h: contentBottom - contentTop)
    }
    private var rightArea: Patch {
        Patch(x: leftArea.right + 28, y: contentTop, w: leftArea.w, h: leftArea.h)
    }

    func setup() {
        frameRate(60)
    }

    func draw() {
        switch phase {
        case 0:
            background(Color(gray: 0.05))
            runOffscreenChecks()
            drawMainProbes()
            loadPixels()
            let reader = MainReader(w: Int(width), h: Int(height), buf: pixels)
            verdicts += judgeMainProbes(reader)
            // 次フレームの漏れ検査は「その位置に元々写っていた色」を起点に期待値を出す。
            leakBackdrop = reader.rgba(MainProbe.leak.cx, MainProbe.leak.cy)
            phase = 1

        case 1:
            // **background を呼ばない**。前フレームを `.multiply` のまま終えた状態が
            // 残っているかを見るので、間に状態を触る呼び出しを挟まない。
            drawFrameLeakProbe()
            loadPixels()
            verdicts += judgeFrameLeak(
                MainReader(w: Int(width), h: Int(height), buf: pixels),
                backdrop: leakBackdrop ?? RGBA8(13, 13, 13))
            phase = 2
            report()
            startRecordingIfAsked()

        default:
            drawArtwork()
            probeState()
            runShotScriptIfAsked()
        }
    }

    // MARK: - 検査

    /// オフスクリーンで完結する検査を 1 回だけ回す。
    ///
    /// `createGraphics` は `setup()` ではなく draw 側で作る（Metal デバイスの準備が
    /// setup 時点で済んでいないことがあるため。0816-adversary も同じ扱い）。
    private func runOffscreenChecks() {
        guard let g = createGraphics(64, 48) else {
            print("!! createGraphics が nil を返した")
            fflush(stdout)
            return
        }
        let sw = Swatch(g)
        swatch = sw
        verdicts += Instrument.runAll(sw)
    }

    private func report() {
        for v in verdicts {
            probe("check.\(v.id)", v.line)
            print(v.line)
        }
        let pass = verdicts.filter(\.passed).count
        probe("check.summary.total", verdicts.count)
        probe("check.summary.pass", pass)
        print("self-check 完了 \(verdicts.count) 件中 PASS \(pass) / FAIL \(verdicts.count - pass)")
        fflush(stdout)
    }

    // MARK: - 作品

    private func drawArtwork() {
        if view == .verdicts {
            drawResults()
            return
        }
        if spinning { spin += 0.0035 }
        if let m = forcedMode { modeIndex = m }
        if demoMode {
            // α を 1 → 0 → 1 と往復させる。光の卓は沈み、絵の具の卓は沈まない、
            // という非対称がこの往復でだけ見える。
            alpha = 0.5 + 0.5 * cos(Float(frameCount) * 0.022)
        }

        background(Color(gray: 0.07))

        switch view {
        case .compare:
            drawTable(.light, in: leftArea, mode: Table.light.mode(modeIndex),
                      alpha: alpha, spread: spread, spin: spin)
            drawTable(.pigment, in: rightArea, mode: Table.pigment.mode(modeIndex),
                      alpha: alpha, spread: spread, spin: spin)
        case .light:
            drawTable(.light, in: fullArea, mode: Table.light.mode(modeIndex),
                      alpha: alpha, spread: spread, spin: spin)
        case .pigment:
            drawTable(.pigment, in: fullArea, mode: Table.pigment.mode(modeIndex),
                      alpha: alpha, spread: spread, spin: spin)
        case .verdicts:
            break
        }

        // 帯より先に読む（HUD を描いてしまうと卓の色が読めなくなる）。
        updateSamples()
        drawHUD()
    }

    /// 卓の重なり点を実測する。30 フレームに 1 回だけ。
    private func updateSamples() {
        guard frameCount % 30 == 0 else { return }
        loadPixels()
        let r = MainReader(w: Int(width), h: Int(height), buf: pixels)

        func read(_ t: Table, _ area: Patch) -> [(String, String, RGBA8)] {
            samplePoints(in: area, spread: spread, spin: spin).prefix(2).map {
                (t.name, $0.label, r.rgba($0.x, $0.y))
            }
        }

        switch view {
        case .compare:
            samples = (read(.light, leftArea) + read(.pigment, rightArea))
                .map { (area: $0.0, label: $0.1, color: $0.2) }
        case .light:
            samples = read(.light, fullArea).map { (area: $0.0, label: $0.1, color: $0.2) }
        case .pigment:
            samples = read(.pigment, fullArea).map { (area: $0.0, label: $0.1, color: $0.2) }
        case .verdicts:
            samples = []
        }

        if traceMode {
            let line = samples.map { "\($0.area)/\($0.label)=\($0.color.rgbText)" }
                .joined(separator: " ")
            print("[trace] view=\(view) mode=\(currentModeName) α=\(Approx.f(alpha, 2)) \(line)")
            fflush(stdout)
        }
    }

    private var currentModeName: String {
        switch view {
        case .pigment: return Table.pigment.modeName(modeIndex)
        case .light, .compare, .verdicts:
            return view == .compare
                ? "\(Table.light.modeName(modeIndex)) / \(Table.pigment.modeName(modeIndex))"
                : Table.light.modeName(modeIndex)
        }
    }

    // MARK: - HUD

    private func drawHUD() {
        blendMode(.alpha)
        noStroke()

        // 上帯。
        fill(Color(r: 0.04, g: 0.05, b: 0.07, a: 0.92))
        rectMode(.corner)
        rect(0, 0, width, contentTop - 8)

        fill(Color(gray: 0.96))
        textSize(21)
        text("光と絵の具 — 同じ 3 原色が、重ね方で白へも黒へも向かう", 28, 34)

        textSize(13)
        fill(Color(gray: 0.62))
        text("\(view.title)    合成: \(currentModeName)    薄め α = \(Approx.f(alpha, 2))"
             + "    開き = \(Approx.f(spread, 2))", 28, 60)

        // α のつまみ。
        let barX: Float = width - 300, barY: Float = 30, barW: Float = 260
        fill(Color(gray: 0.22))
        rect(barX, barY, barW, 8)
        fill(Color(r: 0.35, g: 0.82, b: 0.85))
        rect(barX, barY, barW * alpha, 8)
        fill(Color(gray: 0.55))
        textSize(11)
        text("α（両方の卓に同じ値が効く）", barX, barY + 26)

        // 下帯 — 実測。
        fill(Color(r: 0.04, g: 0.05, b: 0.07, a: 0.94))
        rect(0, contentBottom + 8, width, height - contentBottom - 8)

        fill(Color(gray: 0.55))
        textSize(12)
        text("重なりの実測（30 フレームごとに loadPixels で読み戻し）", 28, contentBottom + 34)

        var x: Float = 28
        for s in samples {
            fill(Color(gray: 0.75))
            textSize(11)
            text("\(s.area) \(s.label)", x, contentBottom + 58)
            blendMode(.opaque)
            fill(Color(r: Float(s.color.r) / 255, g: Float(s.color.g) / 255,
                       b: Float(s.color.b) / 255))
            rect(x, contentBottom + 66, 46, 26)
            blendMode(.alpha)
            fill(Color(gray: 0.62))
            textSize(10)
            text(s.color.rgbText, x + 54, contentBottom + 84)
            x += 160
        }

        // 操作と、検査の要約。
        fill(Color(gray: 0.45))
        textSize(11)
        text("TAB 表示切替   ← → 合成モード   ↑ ↓ 薄め α   SPACE 回転   ドラッグ 開き   ESC 戻す",
             28, height - 16)

        let fails = verdicts.filter { !$0.passed }.count
        fill(fails > 0 ? Color(r: 0.96, g: 0.42, b: 0.34) : Color(r: 0.35, g: 0.82, b: 0.85))
        textSize(11)
        text("自己検査 \(verdicts.count) 件中 FAIL \(fails) 件（TAB で一覧）", width - 300, height - 16)
    }

    private func drawResults() {
        background(Color(gray: 0.05))
        blendMode(.alpha)
        noStroke()
        textSize(11)
        var y: Float = 20
        var x: Float = 14
        for v in verdicts {
            fill(v.passed ? Color(r: 0.35, g: 0.78, b: 0.82) : Color(r: 0.96, g: 0.36, b: 0.30))
            text(v.line.replacingOccurrences(of: "\t", with: "  "), x, y)
            y += 14
            if y > height - 30 {
                y = 20
                x += 640
            }
        }
        fill(Color(gray: 0.5))
        text("TAB で作品へ戻る", 14, height - 12)
    }

    // MARK: - probe

    private func probeState() {
        probe("view", view.title)
        probe("mode", currentModeName)
        probe("alpha", alpha)
        probe("spread", spread)
        for s in samples {
            probe("sample.\(s.area).\(s.label)", s.color.rgbText)
        }
    }

    // MARK: - 観測の口

    /// `GAMUT_FRAMES=<dir>` で GIF 用の連番 PNG を書き出す。
    ///
    /// `saveFrame(_:)` は渡した名前へ無条件で `~/Desktop/` を前置する（metaphor#757）が、
    /// `beginFrameRecord(directory:)` は絶対パスを尊重するのでこちらを使う。
    private func startRecordingIfAsked() {
        guard let dir = framesDir, !recording else { return }
        recording = true
        beginFrameRecord(directory: dir)
        print("[frames] \(dir) へ記録開始")
        fflush(stdout)
    }

    /// `GAMUT_SHOTS=1` で 3 つの表示を 1 枚ずつ書き出して終了する。
    private func runShotScriptIfAsked() {
        guard shotMode else { return }
        // 各表示で少し待ってから撮る（回転が動き出してからの絵にする）。
        guard frameCount % 45 == 0 else { return }
        let names = ["gamut-compare", "gamut-light", "gamut-pigment"]
        guard shotsTaken < names.count else {
            print("[shot] 完了")
            fflush(stdout)
            exit(0)
        }
        saveFrame("\(names[shotsTaken]).png")
        print("[shot] \(names[shotsTaken]).png")
        fflush(stdout)
        shotsTaken += 1
        view = view.next
    }

    // MARK: - 入力

    func keyPressed() {
        guard let code = keyCode else { return }
        let modeCount = Table.light.modes.count
        switch code {
        case TAB: view = view.next
        case LEFT: modeIndex = (modeIndex + modeCount - 1) % modeCount
        case RIGHT: modeIndex = (modeIndex + 1) % modeCount
        case UP: alpha = constrain(alpha + 0.1, 0, 1)
        case DOWN: alpha = constrain(alpha - 0.1, 0, 1)
        case SPACE: spinning.toggle()
        case ESCAPE:
            alpha = 1
            modeIndex = 0
            spread = 1
            spinning = true
            view = .compare
        default: break
        }
    }

    func mouseDragged() {
        spread = constrain(mouseY / max(height, 1) * 2, 0, 2)
    }
}
