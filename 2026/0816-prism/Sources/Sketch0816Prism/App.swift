import Foundation
import metaphor

/// 場面。キー 1〜4 で選ぶ。放っておくと順に巡る。
enum Scene: Int, CaseIterable {
    case dispersion      // 分光 — 白色光が波長ごとに分かれる
    case recombination   // 再合成 — 分かれた光を足し合わせて白へ戻す
    case palette         // 混色 — ブレンドモードの見本
    case aberration      // 収差 — レンズの色ズレ

    var title: String {
        switch self {
        case .dispersion: return "分光 / dispersion"
        case .recombination: return "再合成 / recombination"
        case .palette: return "混色 / palette"
        case .aberration: return "収差 / aberration"
        }
    }

    var hint: String {
        switch self {
        case .dispersion: return "マウス左右で入射角。浅くすると短い波長から全反射で欠ける"
        case .recombination: return "分かれた光を加算で重ねると白へ戻る"
        case .palette: return "同じ 2 色を 10 通りのブレンドで重ねた見本"
        case .aberration: return "マウス左右で色収差の強さ"
        }
    }
}

@main
final class Sketch0816Prism: Sketch {
    var config: SketchConfig {
        SketchConfig(width: 1280, height: 720, title: "0816-prism")
    }

    // MARK: - 検査

    private var verdicts: [Verdict] = []
    private var checked = false
    private let runtime = Runtime()

    // MARK: - 場面

    private var scene: Scene = .dispersion
    private var autoCycle = true
    private var sceneStarted: Float = 0
    /// 1 場面あたりの滞在秒数（自動巡回時）。
    private let dwell: Float = 9

    /// プリズムの向き。マウスで回すと入射角が変わり、浅い側では短い波長から全反射で欠ける。
    ///
    /// マウスが一度も動いていない間はゆっくり自動で振る。放置しても分光が動くので、
    /// 展示でも観測（GIF の書き出し）でも、人が張り付かずに済む。
    private var prismRotation: Float = 0
    private var mouseHasMoved = false
    private static let rotationRange: (min: Float, max: Float) = (-22 * .pi / 180, 20 * .pi / 180)

    /// 入射する光線の進行方向。光源はこの向きから逆算して置く。
    private static let beamAngle: Float = -18 * .pi / 180

    /// 分散の誇張。
    ///
    /// BK7 の実際の分散は n(700)=1.513 〜 n(380)=1.534 で、偏角の差はわずか 1.6°。
    /// そのままだと 640px 先でも 18px しか開かず、虹に見えない（教科書の図が例外なく
    /// 誇張しているのと同じ理由）。**偏角の平均からの差だけを倍にする**ので、
    /// 波長の順序も全反射の起こり方も物理のまま保たれる。画面にも倍率を出す。
    private static let dispersionGain: Float = 9

    /// 色収差の強さ。`aberration` の場面でマウスから決める。
    private var aberrationIntensity: Float = 0.004

    // MARK: - ポストエフェクト

    private var aberration: ChromaticAberrationEffect?
    private var appliedEffectScene: Scene?

    // MARK: - 観測の口

    private let shots = ProcessInfo.processInfo.environment["PRISM_SHOTS"] == "1"
    private let framesDir = ProcessInfo.processInfo.environment["PRISM_FRAMES"]
    private let trap = ProcessInfo.processInfo.environment["PRISM_TRAP"]
    /// `PRISM_SCENE=<0-3>` で 1 場面に固定する。撮影のとき巡回を待たなくて済む。
    private let pinnedScene = ProcessInfo.processInfo.environment["PRISM_SCENE"].flatMap { Int($0) }
    private var shotsTaken = 0
    private var recording = false

    // MARK: - 幾何

    private var prismCenter: (x: Float, y: Float) { (440, height * 0.34) }
    private let prismSide: Float = 200
    private var screenX: Float { width - 160 }

    /// プリズムの 3 頂点。`prismRotation` ぶん中心まわりに回す。
    ///
    /// **絵と計算を同じ回転で駆動する。** 三角形だけ回して入射角を別に持つと、
    /// 見えている向きと Snell に渡す角度が食い違い、絵で検算できなくなる。
    private var prismVertices: (top: (Float, Float), left: (Float, Float), right: (Float, Float)) {
        let c = prismCenter
        let h = prismSide * sqrt(3) / 2
        let base = [(c.x, c.y - h * 2 / 3),
                    (c.x - prismSide / 2, c.y + h / 3),
                    (c.x + prismSide / 2, c.y + h / 3)]
        let r = base.map { rotate($0, around: c, by: prismRotation) }
        return (top: r[0], left: r[1], right: r[2])
    }

    private func rotate(_ p: (Float, Float), around c: (Float, Float), by a: Float) -> (Float, Float) {
        let dx = p.0 - c.0, dy = p.1 - c.1
        return (c.0 + dx * cos(a) - dy * sin(a), c.1 + dx * sin(a) + dy * cos(a))
    }

    /// 光が入る面の中点と、出る面の中点。
    private var entryPoint: (x: Float, y: Float) {
        let v = prismVertices
        return ((v.top.0 + v.left.0) / 2, (v.top.1 + v.left.1) / 2)
    }

    private var exitPoint: (x: Float, y: Float) {
        let v = prismVertices
        return ((v.top.0 + v.right.0) / 2, (v.top.1 + v.right.1) / 2)
    }

    /// 光源。入射点から光線を逆にたどった位置に置く。
    private var sourcePoint: (x: Float, y: Float) {
        let e = entryPoint
        let d: Float = 300
        return (e.x - d * cos(Self.beamAngle), e.y - d * sin(Self.beamAngle))
    }

    /// Snell に渡す入射角。
    ///
    /// 入射面（左上の面）の**外向き法線**は、回転 0 のとき -150° を向く。光線の進行方向と
    /// 内向き法線（+180°）のなす角が入射角になる。プリズムを回すとこの角がそのまま変わる。
    private var incidence: Float {
        let inwardNormal = (-150 * Float.pi / 180 + prismRotation) + .pi
        var a = Self.beamAngle - inwardNormal
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return abs(a)
    }

    // MARK: - ライフサイクル

    func setup() {
        frameRate(60)
        // 層 C は `previousFrame()` で合成後のフレームを読む。フレームバッファ
        // フィードバックは既定で無効で、そのままだと `previousFrame()` は必ず nil を返す
        // （doc の「フィードバックが無効の場合は nil」がこれ）。校正が終わったら
        // `Runtime` 側で無効へ戻し、本編でコピーのコストを払わないようにする。
        enableFeedback()
        if let dir = framesDir {
            // `beginFrameRecord(directory:)` は絶対パスを尊重する
            // （`saveFrame` は無条件に ~/Desktop を前置するので対称ではない → metaphor#757）。
            beginFrameRecord(directory: dir)
            recording = true
        }
    }

    func draw() {
        if !checked {
            checked = true
            runChecks()
            if let name = trap { Trap.fire(name, self) }
        }

        // 層 C の校正はキャンバス全面を使う。終わるまで本編は描き始めない
        // （混ざると、読み戻した色がどちらのものか分からなくなる）。
        if runtime.isCalibrating {
            runtime.step(self)
            return
        }

        advanceScene()
        applyEffects()
        idleSwing()

        background(Color(r: 0.035, g: 0.04, b: 0.055))

        switch scene {
        case .dispersion: drawDispersion()
        case .recombination: drawRecombination()
        case .palette: drawPalette()
        case .aberration: drawAberration()
        }

        drawOverlay()
        handleShots()
    }

    // MARK: - 検査の起動

    /// 層 A と層 B を 1 回だけ走らせる。
    ///
    /// `setup()` ではなく `draw()` の初回に置いているのは、層 B が `createGraphics` を使うから。
    /// オフスクリーンは Metal のデバイスが立ち上がったあとでないと作れない。
    private func runChecks() {
        verdicts = Palette.runAll() + Spectrometer.runAll(self)
        emit(verdicts)
    }

    private func emit(_ list: [Verdict]) {
        for v in list {
            print(v.line)
            probe("check.\(v.id)", v.passed ? "PASS \(v.detail)" : "FAIL \(v.detail)")
        }
        // パイプへ流すとブロックバッファされ、走っていないように見える（#10 で一度誤診した）。
        fflush(stdout)
    }

    /// 層 C から結果を受け取る（フレームを跨ぐ検査は後から届く）。
    ///
    /// 完了行は**全層が出そろってから 1 度だけ**出す。段が届くたびに集計を出すと、
    /// ログを待つ側（`tools/probe.sh`）が途中の集計で打ち切ってしまう。
    func append(_ list: [Verdict]) {
        verdicts += list
        emit(list)
        if runtime.finished { summarize() }
    }

    private func summarize() {
        let failed = verdicts.filter { !$0.passed }
        print("self-check 完了: \(verdicts.count - failed.count) PASS / \(failed.count) FAIL")
        probe("check.summary", "\(verdicts.count - failed.count) PASS / \(failed.count) FAIL")
        fflush(stdout)
    }

    // MARK: - 場面の進行

    private func advanceScene() {
        if let pin = pinnedScene, let fixed = Scene(rawValue: pin) {
            scene = fixed
            autoCycle = false
            return
        }
        if sceneStarted == 0 { sceneStarted = time }
        guard autoCycle, time - sceneStarted > dwell else { return }
        let all = Scene.allCases
        scene = all[(scene.rawValue + 1) % all.count]
        sceneStarted = time
    }

    /// 誰も触っていない間だけ、プリズムと収差をゆっくり振る。
    private func idleSwing() {
        guard !mouseHasMoved else { return }
        let r = Self.rotationRange
        let t = 0.5 + 0.5 * sin(time * 0.42)
        prismRotation = r.min + (r.max - r.min) * t
        aberrationIntensity = 0.0005 + 0.02 * (0.5 + 0.5 * sin(time * 0.7))
    }

    private func applyEffects() {
        guard appliedEffectScene != scene else {
            if scene == .aberration { aberration?.intensity = aberrationIntensity }
            return
        }
        appliedEffectScene = scene
        clearPostEffects()
        if scene == .aberration {
            let effect = ChromaticAberrationEffect(intensity: aberrationIntensity)
            aberration = effect
            addPostEffect(effect)
        } else {
            aberration = nil
        }
    }

    // MARK: - 分光

    private func drawDispersion() {
        let entry = entryPoint
        let exit = exitPoint

        drawScreenPlate()
        drawSourceGlow()

        // 入射する白色光。ここはまだ 1 本。
        blendMode(.alpha)
        stroke(Color(r: 1, g: 1, b: 0.96, alpha: 0.85))
        strokeWeight(3)
        line(sourcePoint.x, sourcePoint.y, entry.x, entry.y)

        drawPrism()

        // ガラスの中の光路。入射面と出射面の中点を結ぶ近似で、内部の屈折までは追わない。
        stroke(Color(r: 0.9, g: 0.95, b: 1, alpha: 0.35))
        strokeWeight(2)
        line(entry.x, entry.y, exit.x, exit.y)

        // 出射光。波長ごとに偏角が違うので、ここで扇に開く。
        // 加算で重ねるので、重なったところは自然に明るくなる。
        blendMode(.additive)
        strokeWeight(2)
        var blocked = 0
        let rays = Optics.spectrum(count: 72)
        // 誇張の基準は可視域の真ん中（540nm）。ここからの差だけを広げるので、
        // 順序も全反射も物理のまま、開き方だけが見える大きさになる。
        let reference = Optics.deviation(incidence: incidence, index: Optics.refractiveIndex(540))

        for ray in rays {
            let n = Optics.refractiveIndex(ray.nm)
            guard let raw = Optics.deviation(incidence: incidence, index: n) else {
                blocked += 1   // 全反射して出てこない波長
                continue
            }
            let delta = reference.map { $0 + (raw - $0) * Self.dispersionGain } ?? raw
            let angle = Self.beamAngle + delta
            let t = (screenX - exit.x) / cos(angle)
            guard t > 0 else { continue }
            let hitY = exit.y + t * sin(angle)

            stroke(ray.color.withAlpha(0.5))
            line(exit.x, exit.y, screenX, hitY)

            // スクリーンに落ちた帯。
            noStroke()
            fill(ray.color.withAlpha(0.9))
            rect(screenX, hitY - 4, 90, 8)
        }

        blendMode(.alpha)
        drawLabel("入射角 \(Int(incidence * 180 / .pi))°　n(700nm)=\(fmt(Optics.refractiveIndex(700)))　n(380nm)=\(fmt(Optics.refractiveIndex(380)))"
            + "　開きは \(Int(Self.dispersionGain)) 倍に誇張（実際の偏角差は約 1.6°）"
            + (blocked > 0 ? "　全反射で欠けた波長 \(blocked)/\(rays.count)" : ""),
            24, height - 34)
    }

    // MARK: - 再合成

    private func drawRecombination() {
        let focus = (x: screenX - 40, y: height * 0.5)
        let origin = (x: prismCenter.x - 120, y: height * 0.5)
        let spread: Float = 150

        drawSourceGlow()

        // 分かれた光を、いったん縦に開いてから 1 点へ集める。
        // 焦点に近づくほど重なりが増え、加算の結果として白へ戻る。
        blendMode(.additive)
        strokeWeight(2)
        let rays = Optics.spectrum(count: 72)
        for (i, ray) in rays.enumerated() {
            let t = Float(i) / Float(rays.count - 1)
            let fanY = origin.y - spread + spread * 2 * t
            stroke(ray.color.withAlpha(0.45))
            line(origin.x, origin.y, origin.x + 180, fanY)
            line(origin.x + 180, fanY, focus.x, focus.y)
        }

        // 焦点。1 色ずつ加算で重ねた円が白へ収束していく様子をそのまま出す。
        noStroke()
        for ray in rays {
            fill(ray.color.withAlpha(0.06))
            circle(focus.x, focus.y, 96)
        }

        blendMode(.alpha)
        drawLabel("72 本の単色光を blendMode(.additive) で重ねている。焦点の色が白へ戻れば加算が正しい",
            24, height - 34)
    }

    // MARK: - 混色の見本

    private func drawPalette() {
        let modes: [(BlendMode, String)] = [
            (.alpha, "alpha"), (.additive, "additive"), (.multiply, "multiply"),
            (.screen, "screen"), (.difference, "difference"), (.exclusion, "exclusion"),
            (.darkest, "darkest"), (.lightest, "lightest"), (.subtract, "subtract"),
            (.opaque, "opaque"),
        ]
        let cols = 5
        let cellW = (width - 120) / Float(cols)
        let cellH: Float = 190
        let top = height * 0.5 - cellH

        for (i, entry) in modes.enumerated() {
            let cx = 60 + cellW * (Float(i % cols) + 0.5)
            let cy = top + cellH * Float(i / cols) + cellH * 0.42

            // 下地の円（dst）。ブレンドの影響を受けないよう不透明で置く。
            blendMode(.opaque)
            noStroke()
            fill(Color(r: 0.2, g: 0.4, b: 0.6))
            circle(cx - 24, cy, 108)

            // 重ねる円（src）。ここだけモードを変える。
            blendMode(entry.0)
            fill(Color(r: 0.85, g: 0.55, b: 0.15))
            circle(cx + 24, cy, 108)

            blendMode(.alpha)
            fill(Color(r: 0.75, g: 0.78, b: 0.85))
            textSize(13)
            text(entry.1, cx - 32, cy + 78)
        }

        drawLabel("dst=(0.20,0.40,0.60) の上に src=(0.85,0.55,0.15) を重ねた 10 通り",
            24, height - 34)
    }

    // MARK: - 収差

    private func drawAberration() {
        // 色収差は「白い細部ほど目立つ」ので、細い同心円と文字を置く。
        blendMode(.alpha)
        noFill()
        strokeWeight(2)
        for i in 0..<9 {
            let r = 90 + Float(i) * 52
            let shade = 0.95 - Float(i) * 0.06
            stroke(Color(gray: shade))
            circle(width * 0.5, height * 0.5, r)
        }

        noStroke()
        fill(Color.white)
        textSize(46)
        text("PRISM", width * 0.5 - 86, height * 0.5 + 14)

        drawLabel("ChromaticAberrationEffect(intensity: \(fmt(aberrationIntensity, 4)))  — 白い輪郭ほど RGB がずれる",
            24, height - 34)
    }

    // MARK: - 部品

    private func drawPrism() {
        let v = prismVertices
        blendMode(.alpha)
        fill(Color(r: 0.62, g: 0.76, b: 0.92, alpha: 0.13))
        stroke(Color(r: 0.78, g: 0.88, b: 1.0, alpha: 0.55))
        strokeWeight(2)
        triangle(v.top.0, v.top.1, v.left.0, v.left.1, v.right.0, v.right.1)
        noStroke()
    }

    /// 光源のにじみ。`radialGradient` を本編の経路に通す。
    private func drawSourceGlow() {
        blendMode(.additive)
        radialGradient(sourcePoint.x, sourcePoint.y, 78,
                       Color(r: 1, g: 0.98, b: 0.92, alpha: 0.55), Color.clear,
                       segments: 48)
        blendMode(.alpha)
    }

    /// スクリーン板。`linearGradient` を本編の経路に通す。
    private func drawScreenPlate() {
        blendMode(.alpha)
        linearGradient(screenX, 60, 84, height - 120,
                       Color(r: 0.10, g: 0.11, b: 0.14),
                       Color(r: 0.04, g: 0.04, b: 0.06),
                       axis: .vertical)
    }

    private func drawLabel(_ s: String, _ x: Float, _ y: Float) {
        noStroke()
        fill(Color(r: 0.62, g: 0.66, b: 0.74))
        textSize(13)
        text(s, x, y)
    }

    /// 検査の要約。FAIL があるときだけ赤くして目立たせる。
    private func drawOverlay() {
        blendMode(.alpha)
        noStroke()
        let failed = verdicts.filter { !$0.passed }
        fill(Color(r: 0.88, g: 0.90, b: 0.94))
        textSize(15)
        text("0816-prism — \(scene.title)", 24, 32)
        textSize(12)
        fill(Color(r: 0.55, g: 0.58, b: 0.66))
        text(scene.hint, 24, 52)

        if verdicts.isEmpty { return }
        if failed.isEmpty {
            fill(Color(r: 0.42, g: 0.78, b: 0.55))
            text("self-check \(verdicts.count) 件すべて PASS", 24, 74)
        } else {
            fill(Color(r: 0.95, g: 0.36, b: 0.36))
            text("self-check FAIL \(failed.count) / \(verdicts.count)", 24, 74)
            for (i, v) in failed.prefix(6).enumerated() {
                text("· \(v.id)", 24, 94 + Float(i) * 17)
            }
        }
    }

    private func fmt(_ v: Float, _ digits: Int = 3) -> String {
        String(format: "%.\(digits)f", v)
    }

    // MARK: - 書き出し

    /// `PRISM_SHOTS=1` のとき、場面ごとに 1 枚だけ焼いて終わる。巡回を待たずに絵を取れる。
    private func handleShots() {
        guard shots else { return }
        // 各場面で少しだけ待ってから撮る（グラデーションとエフェクトが乗った状態にする）。
        guard frameCount % 30 == 0 else { return }
        // `saveFrame` は渡した名前に無条件で ~/Desktop を前置する（metaphor#757）。
        saveFrame("prism-\(scene.rawValue)-\(String(describing: scene)).png")
        shotsTaken += 1
        let all = Scene.allCases
        if shotsTaken >= all.count {
            if recording { endFrameRecord() }
            print("shots 完了: \(shotsTaken) 枚")
            fflush(stdout)
            exit(0)
        }
        scene = all[(scene.rawValue + 1) % all.count]
        sceneStarted = time
        autoCycle = false
    }

    // MARK: - 入力

    func mouseMoved() {
        mouseHasMoved = true
        let t = min(max(mouseX / max(width, 1), 0), 1)
        switch scene {
        case .dispersion:
            let r = Self.rotationRange
            prismRotation = r.min + (r.max - r.min) * t
        case .aberration:
            aberrationIntensity = 0.0005 + 0.02 * t
        default:
            break
        }
        runtime.noteInput("mouseMoved")
    }

    func mousePressed() {
        runtime.noteInput("mousePressed")
    }

    func keyPressed() {
        runtime.noteInput("keyPressed")
        guard let k = key else { return }
        switch k {
        case "1", "2", "3", "4":
            if let n = k.wholeNumberValue, let s = Scene(rawValue: n - 1) {
                scene = s
                sceneStarted = time
                autoCycle = false
            }
        case " ":
            autoCycle.toggle()
            sceneStarted = time
        case "r", "R":
            verdicts = []
            checked = false
        default:
            break
        }
    }
}
