import Foundation
import simd
import metaphor

// 0816-atelier — アトリエ。
//
// 石膏デッサンの静物を組み込みの 3D で描き、**作品自身が講師の赤鉛筆になって**
// 形・明暗・奥行き・影・手の狂いを測る。
//
// 1 場面は「採寸」と「デッサン」の二段構え:
//
//   採寸  標本をひとつずつ画面中央に置き、寸法・明暗・位置を実測して
//         手で解いた期待値と突き合わせる（決定論。時計も乱数も見ない）
//   素描  石膏の静物ひと揃いをランプとカメラを回しながら見せる
//
// 判定の出どころは `frame.json` の `custom`（`check.<ID>`）と標準出力の両方。
// 詳しい経緯は検証記録 metaphor-sketches#17。

/// 採寸台に載せる標本 1 件。
///
/// 描画と判定は場面ごとのファイルが `switch` で受け持つ（クロージャを持たせると
/// スケッチ自身との循環参照になり、標本を足すたびに気を使うことになるため）。
struct Specimen {
    /// 判定 ID の接尾辞。完全な ID は `<場面の文字><通番>.<name>`。
    let name: String
    /// 採寸台に出す標本名。
    let title: String
    /// 何を測っているのかの一行。
    let note: String
}

@main
final class Sketch0816Atelier: Sketch {
    var config: SketchConfig {
        SketchConfig(width: 1280, height: 720, title: "0816-atelier")
    }

    // MARK: 判定の置き場

    /// ID 順に保つ（同じ ID が来たら差し替え）。
    var findings: [Finding] = []
    private var findingSlot: [String: Int] = [:]
    /// 一巡目で判定を出し終えた場面。全部そろったら「self-check 完了」を出す。
    private var judgedStages: Set<Int> = []
    private var announcedDone = false

    // MARK: 観測の口（環境変数）

    let env = ProcessInfo.processInfo.environment
    /// 1 場面に固定して見たいとき。
    lazy var pinnedStage: Int? = env["ATELIER_STAGE"].flatMap { Int($0) }.map { max(0, min(4, $0 - 1)) }
    /// 場面ごとに 1 枚ずつ書き出す。
    lazy var wantShots: Bool = env["ATELIER_SHOTS"] == "1"
    /// GIF 用の連番 PNG の出力先。
    lazy var framesDir: String? = env["ATELIER_FRAMES"]
    /// 落ちうる口を、頼んだときだけ再現する。
    lazy var trapName: String? = env["ATELIER_TRAP"]

    private var shotTaken: Set<Int> = []

    // MARK: 場面ごとの持ち物

    /// 場面 5「手」で使う、`setup()` で組んだメッシュ。
    var handMeshes: [String: Mesh] = [:]
    /// 場面 5 で当てるカスタムマテリアル（最小の MSL 1 本）。
    var flatMaterial: CustomMaterial?
    /// 場面 5 のテクスチャ（手続きで作った市松）。
    var checkerImage: MImage?
    /// 標本をまたいで持ち越したい実測値（影の解像度比較など）。
    var scratch: [String: Float] = [:]

    // MARK: - ライフサイクル

    func setup() {
        frameRate(60)

        emit("0816-atelier — 石膏デッサンで基本的な 3D を測る")
        emit("キャンバス \(f0(width))x\(f0(height)) / 既定カメラの視距離 defaultZ=\(f2(Optics.standardZ(height: height)))")
        emit("（z=0 の平面では 1 ワールド単位 = 1 ピクセル。深さ z での倍率は defaultZ/(defaultZ-z)）")

        if trapName != nil {
            // 落ちうる口は描画を伴うものが多いので、実行はフレームの中（draw）へ回す。
            return
        }

        Timing.configureFast(env["ATELIER_FAST"] == "1")
        prepareHand()
        buildSchedule()
        emit("採寸: 形 \(formSpecimens().count) / 明暗 \(valueSpecimens().count) / 奥行き \(depthSpecimens().count)"
            + " / 影 \(shadowSpecimens().count) / 手 \(handSpecimens().count) 件")
        emit("一巡 \(cycleFrames) フレーム（\(f1(Float(cycleFrames) / 60)) 秒）"
            + (Timing.fast ? " / ATELIER_FAST: 素描を畳んで採寸だけ回す" : ""))

        if let dir = framesDir {
            // beginFrameRecord は絶対パスを尊重する（saveFrame は無条件で ~/Desktop を前置する = metaphor#757）。
            beginFrameRecord(directory: dir, pattern: "atelier_%05d.png")
            emit("連番 PNG → \(dir)")
        }
    }

    func draw() {
        if let trap = trapName {
            background(Palette.ground.x, Palette.ground.y, Palette.ground.z)
            runTrap(trap)
            // 落ちなかったことを見せたいだけなので、1 フレームで畳む。
            exit(0)
        }

        let frame = frameCount
        let (stageIndex, local, cycle) = locate(frame)
        let stage = Stage(rawValue: stageIndex) ?? .form

        let specimens = specimenList(stage)
        let measureFrames = specimens.count * Timing.holdFrames
        let sceneFrames = stageLengths[stageIndex]

        background(Palette.ground.x, Palette.ground.y, Palette.ground.z)
        noStroke()

        if local < measureFrames {
            let index = local / Timing.holdFrames
            let held = local % Timing.holdFrames
            // 影の場面以外ではシャドウを落としておく。**読み戻しの都合**で、
            // シャドウが有効な間の `loadPixels()` は同一フレームを読めず
            // 「直前に確定したフレーム」を返す（metaphor が警告で言う）。
            // 前フレームには講評欄と見出しが乗っているので、そのまま測ると
            // シルエットにパネルの矩形が混ざる（実際に一度混ざった）。
            if stage != .shadow { disableShadows() }
            drawSpecimen(stage, index)
            // 判定は 1 件につき 2 回。**間を空けるのは影のため。**
            //
            // シャドウ深度パスはメインパスの**後**に走る（`Canvas3D.performShadowPass`）ので、
            // あるフレームが読むシャドウマップは 1 フレーム前の描画で作られたもの。
            // 標本を差し替えた直後に測ると、前の標本の影を見てしまう。
            // pass 0（差し替え直後）と pass 1（落ち着いた後）を両方撮って、その差も検査に使う。
            if held == Timing.earlyPass || held == Timing.settledPass {
                // 読み戻しは 1 フレームに 1 回だけ。ここより後に描いたものは判定に混ざらない。
                loadPixels()
                let canvas = Canvas(w: Int(width), h: Int(height), buf: pixels,
                                    ground: Palette.ground, threshold: 26)
                let pass = held == Timing.earlyPass ? 0 : 1
                for f in judgeSpecimen(stage, index, canvas, pass) { record(f) }
                if pass == 1 && index == specimens.count - 1 { finishStage(stageIndex) }
            }
            drawSpecimenCaption(stage, index, specimens[index], local: local)
        } else {
            let t = Float(local - measureFrames) / Float(max(sceneFrames - measureFrames, 1))
            drawStillLife(phase: t, stage: stage)
            drawStudyCaption(stage, progress: t)
            takeShotIfAsked(stageIndex, progress: t)
        }

        drawCritique(stage)
        publishProbes(stage: stage, local: local, cycle: cycle)
    }

    // MARK: - 判定の記録

    func record(_ f: Finding) {
        if let slot = findingSlot[f.id] {
            // 二巡目以降。数値が変わったら決定論が崩れているので、そこだけ言う。
            if findings[slot].line != f.line {
                emit("[!] \(f.id) の判定が前巡と違う: \(findings[slot].line) → \(f.line)")
            }
            findings[slot] = f
        } else {
            findingSlot[f.id] = findings.count
            findings.append(f)
            emit(f.line)
        }
    }

    private func finishStage(_ stageIndex: Int) {
        judgedStages.insert(stageIndex)
        guard !announcedDone, judgedStages.count == Timing.stageCount || pinnedStage != nil else { return }
        announcedDone = true
        let fails = findings.filter { $0.verdict.isFail }
        let looks = findings.filter { if case .look = $0.verdict { return true }; return false }
        emit("---")
        emit("self-check 完了: \(findings.count) 件中 直し \(fails.count) 件 / 要確認 \(looks.count) 件")
        for f in fails { emit("  直し \(f.line)") }
        for f in looks { emit("  要確認 \(f.line)") }
    }

    // MARK: - 時間割

    /// 場面ごとのフレーム数。素描を畳むモードでは採寸ぶんだけになる。
    private(set) var stageLengths: [Int] = []
    var cycleFrames: Int { stageLengths.reduce(0, +) }

    private func buildSchedule() {
        stageLengths = Stage.allCases.map { stage in
            let measure = specimenList(stage).count * Timing.holdFrames
            return Timing.fast ? measure : max(Timing.sceneFrames, measure + 120)
        }
    }

    /// 通しフレーム番号から（場面・場面内フレーム・何巡目）を割り出す。
    private func locate(_ frame: Int) -> (stage: Int, local: Int, cycle: Int) {
        if let pinned = pinnedStage {
            let len = stageLengths[pinned]
            return (pinned, frame % len, frame / len)
        }
        let total = cycleFrames
        let cycle = frame / total
        var rest = frame % total
        for (k, len) in stageLengths.enumerated() {
            if rest < len { return (k, rest, cycle) }
            rest -= len
        }
        return (Timing.stageCount - 1, 0, cycle)
    }

    // MARK: - 場面ごとの割り振り

    func specimenList(_ stage: Stage) -> [Specimen] {
        switch stage {
        case .form: return formSpecimens()
        case .value: return valueSpecimens()
        case .depth: return depthSpecimens()
        case .shadow: return shadowSpecimens()
        case .hand: return handSpecimens()
        }
    }

    private func drawSpecimen(_ stage: Stage, _ i: Int) {
        switch stage {
        case .form: drawFormSpecimen(i)
        case .value: drawValueSpecimen(i)
        case .depth: drawDepthSpecimen(i)
        case .shadow: drawShadowSpecimen(i)
        case .hand: drawHandSpecimen(i)
        }
    }

    /// `pass` は 0 = 標本を差し替えた直後、1 = 落ち着いた後。
    /// 影以外の場面は pass 1 だけを見る（pass 0 は影の 1 フレーム遅れを測るためにある）。
    private func judgeSpecimen(_ stage: Stage, _ i: Int, _ c: Canvas, _ pass: Int) -> [Finding] {
        switch stage {
        case .shadow: return judgeShadowSpecimen(i, c, pass)
        case .form: return pass == 1 ? judgeFormSpecimen(i, c) : []
        case .value: return pass == 1 ? judgeValueSpecimen(i, c) : []
        case .depth: return pass == 1 ? judgeDepthSpecimen(i, c) : []
        case .hand: return pass == 1 ? judgeHandSpecimen(i, c) : []
        }
    }

    /// 判定に使うカメラ模型。**採寸中は `camera()` を呼ばない**ので既定のまま。
    var standardOptics: Optics { Optics.standard(width: width, height: height) }

    /// 採寸台の中心（既定カメラの視軸）。
    var axis: SIMD3<Float> { SIMD3(width / 2, height / 2, 0) }

    // MARK: - 素描（作品の側）

    private func drawStillLife(phase: Float, stage: Stage) {
        let lampPos = Studio.lampPosition(phase: phase, width: width)
        let eye = Studio.orbitEye(phase: phase, width: width, height: height)
        camera(eye: eye, center: Studio.orbitCenter(width: width, height: height))

        ambientLight(56)

        // 主光。灯から台の中心へ向かう平行光にしておくと、影の向きが灯と一致して読める。
        let target = SIMD3<Float>(width / 2, Studio.floorY, Studio.floorZ)
        let travel = normalize(target - lampPos)
        directionalLight(travel.x, travel.y, travel.z,
                         color: Color(r: 1.0, g: 0.94, b: 0.84))
        // 灯そのものの近接光。既定の falloff(0.1) はピクセル空間だと届かないので、
        // 実際に効く値まで落としてある（場面 2 の V5 がその根拠を数値で出す）。
        pointLight(lampPos.x, lampPos.y, lampPos.z,
                   color: Color(r: 1.0, g: 0.88, b: 0.68), falloff: 0.0012)

        enableShadows(resolution: 1024)
        shadowBias(0.0045)

        drawRoom()
        drawCasts(spin: phase * 0.7)
        drawLamp(at: lampPos)
        _ = stage
    }

    private func takeShotIfAsked(_ stageIndex: Int, progress: Float) {
        guard wantShots, progress > 0.35, !shotTaken.contains(stageIndex) else { return }
        shotTaken.insert(stageIndex)
        // saveFrame は渡した名前に無条件で ~/Desktop/ を前置する（metaphor#757）。
        saveFrame("atelier-\(stageIndex + 1).png")
        emit("→ ~/Desktop/atelier-\(stageIndex + 1).png")
    }

    // MARK: - 観測へ流す

    private func publishProbes(stage: Stage, local: Int, cycle: Int) {
        probe("stage", stage.title)
        probe("stage.index", stage.rawValue + 1)
        probe("cycle", cycle)
        probe("local", local)
        probe("checks.total", findings.count)
        probe("checks.fail", findings.filter { $0.verdict.isFail }.count)
        for f in findings {
            probe("check.\(f.id)", "\(f.verdict.token) \(f.verdict.detail)")
        }
    }
}
