import Foundation
import metaphor
import simd

// 0816-marionette — 2D の物理が 3D の骨組みを操る。
//
// 物理は平面（XY）で解き、その平面ごとシーングラフのノードで 3D 空間に吊る。
// 見えているのは吊られた構造物で、動かしているのは平面上の Verlet 積分。
//
// 検証の一次記録は frame.json の `custom`。`check.*` に決定論的な検査（Instrument.swift）、
// それ以外に毎フレームの実測値が載る。詳細は README と本リポジトリの検証 issue。

@main
final class Sketch0816Marionette: Sketch, LinkPainter {
    var config: SketchConfig {
        SketchConfig(width: 1600, height: 900, title: "0816-marionette", preserveClock: true)
    }

    // MARK: - 調整できる値

    @Param(min: 0, max: 2.5) var wind: Float = 1.0
    @Param(min: 5, max: 600) var holdSeconds: Float = 45
    @Param(min: 0, max: 3) var orbitScale: Float = 1.0
    @Param var autoAdvance: Bool = true
    @Param var showLinks: Bool = true
    @Param var showHUD: Bool = true
    @Param var cullingEnabled: Bool = true

    // MARK: - 状態

    private var stages: [Stage] = []
    private var stageIndex = 0
    private var stageSwitches = 0
    private var stageEnteredAt: Float = 0
    private var startedAt: Float = 0
    private var worstFrameMs: Float = 0
    private var lastSubSteps = 0
    private var verdicts: [Verdict] = []
    private var culledNodes = 0
    private var frustumPlanes: [SIMD4<Float>]?

    /// 場面切り替えの明滅。未検証だった `Tween` をここで通す。
    private var flash: Tween<Float>?

    private var stage: Stage { stages[stageIndex] }

    // MARK: - 準備

    func setup() {
        frameRate(60)

        // 決定論的な検査を 1 回だけ走らせ、標準出力にも残す（ソークのログ用）
        verdicts = Instrument.runAll()
        let failed = verdicts.filter { !$0.passed }
        var report = "[marionette] self-check \(verdicts.count - failed.count)/\(verdicts.count) PASS\n"
        for verdict in verdicts {
            report += "  \(verdict.passed ? "PASS" : "FAIL") \(verdict.id)  \(verdict.detail)\n"
        }
        // パイプへ流すとブロックバッファされるので、確実に出るよう自分で吐き出す
        print(report, terminator: "")
        fflush(stdout)

        let kit = MeshKit(
            cell: createSphereMesh(1, detail: 16),
            brick: createBoxMesh(1)
        )
        stages = [
            ChainStage(kit: kit, painter: self),
            ClothStage(kit: kit, painter: self),
            PitStage(kit: kit),
            SwarmStage(kit: kit),
        ]

        startedAt = time
        stageEnteredAt = time
    }

    // MARK: - 毎フレーム

    func draw() {
        let frameStart = deltaTime * 1000
        if time - startedAt > 2 { worstFrameMs = max(worstFrameMs, frameStart) }

        advanceStageIfNeeded()

        let stage = self.stage
        let elapsed = time - stageEnteredAt

        // 力を加えてから、固定刻みで物理を進め、結果をノードへ写す
        stage.drive(time: time, wind: wind)
        lastSubSteps = stage.rig.step(elapsed: max(deltaTime, 1.0 / 240.0))
        stage.rig.sync()

        background(4, 6, 11)
        setupCamera(for: stage)
        setupLights()

        drawStage(stage)
        if showHUD { drawHUD(stage, elapsed: elapsed) }

        emitProbes(stage, elapsed: elapsed)
        saveShotIfRequested(stage, elapsed: elapsed)
        recordFramesIfRequested(stage, elapsed: elapsed)

        if ProcessInfo.processInfo.environment["MARIONETTE_TRACE"] == "1", frameCount % 120 == 0,
           let plane = stage.rig.planes.first, let head = plane.strands.first, let tail = plane.strands.last {
            let headWorld = head.node.worldTransform.columns.3
            let tailWorld = tail.node.worldTransform.columns.3
            print(String(
                format: "[screen] world y=+250 → screenY=%.0f / y=0 → %.0f / y=-250 → %.0f  (canvas height=%.0f)",
                screenY(0, 250, 0), screenY(0, 0, 0), screenY(0, -250, 0), height
            ))
            print(String(
                format: "[trace] f=%d %@ pivot=(%.0f,%.0f,%.0f) head body=(%.0f,%.0f) world=(%.0f,%.0f,%.0f) tail body=(%.0f,%.0f) world=(%.0f,%.0f,%.0f)",
                frameCount, stage.name,
                plane.pivot.position.x, plane.pivot.position.y, plane.pivot.position.z,
                head.body.position.x, head.body.position.y, headWorld.x, headWorld.y, headWorld.z,
                tail.body.position.x, tail.body.position.y, tailWorld.x, tailWorld.y, tailWorld.z
            ))
            fflush(stdout)
        }
    }

    // MARK: - 場面

    private func advanceStageIfNeeded() {
        // 撮影モードでは 4 場面を短時間で一巡させる
        let hold = ProcessInfo.processInfo.environment["MARIONETTE_SHOTS"] != nil ? 12 : holdSeconds
        guard autoAdvance, time - stageEnteredAt > hold else { return }
        go(to: (stageIndex + 1) % stages.count)
    }

    private func go(to index: Int) {
        guard index != stageIndex, stages.indices.contains(index) else { return }
        stageIndex = index
        stageEnteredAt = time
        stageSwitches += 1
        flash = tween(from: 1.0, to: 0.0, duration: 1.2, easing: easeOutCubic)
    }

    private func setupCamera(for stage: Stage) {
        perspective(fov: .pi / 3.2, near: 5, far: 6000)
        let view = stage.camera(time: time, orbit: orbitScale)
        camera(eye: view.eye, center: view.center, up: SIMD3(0, 1, 0))
    }

    private func setupLights() {
        ambientLight(0.55)
        // Y は画面の下向きなので、上から当てる光は +Y ではなく -Y 側から来る
        directionalLight(-0.35, 0.85, -0.4, color: Color(r: 1.0, g: 0.95, b: 0.88))
        directionalLight(0.6, -0.3, 0.7, color: Color(r: 0.42, g: 0.58, b: 0.95))
    }

    private func drawStage(_ stage: Stage) {
        noStroke()
        metallic(0.0)
        roughness(0.55)
        emissive(0.10)

        let rig = stage.rig
        // pit は実行中にノードが増減するので、変わったら番号を振り直す
        if rig.indexedCount != rig.nodeCount { rig.reindex() }
        rig.counter.reset()

        if stage.usesCulling && cullingEnabled {
            // カリングの判定は worldTransform 基準なので、キャンバスの変換が
            // 単位行列のうちにルートから呼ぶ（SceneRenderer の doc の注意点）
            let planes = SceneRenderer.extractFrustumPlanes(from: context.canvas3D.currentViewProjection)
            frustumPlanes = planes
            SceneRenderer.render(node: rig.root, canvas: context.canvas3D, frustumPlanes: planes)
        } else {
            frustumPlanes = nil
            drawScene(rig.root)
        }

        culledNodes = max(0, rig.nodeCount - rig.counter.drawn)
        cullingMisses = auditCulling(rig)

        // 切り替え直後の明滅
        if let flash, flash.isActive {
            let intensity = flash.value
            push()
            noLights()
            fill(Color(r: 0.7, g: 0.8, b: 1.0, a: intensity * 0.5))
            translate(width * 0.5, height * 0.5)
            rect(0, 0, width, height)
            pop()
        }
    }

    /// カリングの取りこぼしを数える。
    ///
    /// 「画面のはっきり内側に投影されるノード」は必ず描かれていなければならない。
    /// フラスタム判定が保守的に外す（残しすぎる）のは許されるが、見えているものを
    /// 消すのは許されない。その一方向だけを 1 ノードずつ照合する。
    ///
    /// 判定にはカリングと同じビュー投影行列を使い、**自分でクリップ空間まで戻す**。
    /// `screenX` / `screenY` は `clip.w` で割った後の値しか返さず、`screenZ` も
    /// `clip.z / clip.w` なので、`clip.w < 0`（カメラの背後）でも符号が反転して
    /// 「画面内」に見えてしまい、そのままでは偽の取りこぼしを数えてしまう。
    private func auditCulling(_ rig: Rig) -> Int {
        guard frustumPlanes != nil else { return 0 }
        let viewProjection = context.canvas3D.currentViewProjection
        // 端はメッシュの半径ぶん曖昧なので、内側だけを見る
        let margin: Float = 0.12
        var misses = 0

        for (index, strand) in rig.indexedStrands() {
            let world = strand.node.worldTransform.columns.3
            let clip = viewProjection * SIMD4<Float>(world.x, world.y, world.z, 1)
            // 背後（w <= 0）と、ニア/ファーの外は「見えている」に数えない
            guard clip.w > 0 else { continue }
            let ndc = SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
            guard ndc.z > 0, ndc.z < 1 else { continue }
            guard abs(ndc.x) < 1 - margin, abs(ndc.y) < 1 - margin else { continue }
            if !rig.counter.wasDrawn(index) { misses += 1 }
        }
        return misses
    }

    private var cullingMisses = 0

    // MARK: - 拘束の線

    func paintLinks(_ pairs: [(PhysicsBody2D, PhysicsBody2D)], color: Color, weight: Float) {
        guard showLinks, !pairs.isEmpty else { return }
        pushStyle()
        noFill()
        stroke(color)
        strokeWeight(weight)
        beginShape3D(.lines)
        for (a, b) in pairs {
            vertex(a.position.x, a.position.y, 0)
            vertex(b.position.x, b.position.y, 0)
        }
        endShape()
        popStyle()
    }

    // MARK: - HUD

    private func drawHUD(_ stage: Stage, elapsed: Float) {
        let failed = verdicts.filter { !$0.passed }
        push()
        noLights()
        fill(Color(r: 0.86, g: 0.90, b: 0.98))
        textSize(17)
        text("marionette / \(stage.name)", 28, 40)
        textSize(13)
        fill(Color(r: 0.58, g: 0.66, b: 0.80))
        text(String(format: "%.0fs / %.0fs   bodies %d   constraints %d", elapsed, holdSeconds, stage.rig.bodyCount, stage.rig.constraintCount), 28, 64)
        let missText = frustumPlanes != nil ? "   culling misses \(cullingMisses)" : ""
        text("nodes \(stage.rig.counter.drawn) drawn / \(culledNodes) culled   substeps \(lastSubSteps)" + missText, 28, 84)

        if failed.isEmpty {
            fill(Color(r: 0.45, g: 0.82, b: 0.58))
            text("self-check \(verdicts.count)/\(verdicts.count) PASS", 28, 108)
        } else {
            fill(Color(r: 0.95, g: 0.42, b: 0.42))
            text("self-check FAIL: " + failed.map(\.id).joined(separator: " "), 28, 108)
        }
        pop()
    }

    // MARK: - 観測

    private func emitProbes(_ stage: Stage, elapsed: Float) {
        probe("stage", stage.name)
        probe("stageIndex", stageIndex)
        probe("stageSwitches", stageSwitches)
        probe("stageElapsedSec", Double(elapsed))
        probe("uptimeSec", Double(time - startedAt))
        probe("worstFrameMs", Double(worstFrameMs))

        probe("bodies", stage.rig.bodyCount)
        probe("constraints", stage.rig.constraintCount)
        probe("nodes", stage.rig.nodeCount)
        probe("nodesDrawn", stage.rig.counter.drawn)
        probe("nodesCulled", culledNodes)
        probe("cullingActive", frustumPlanes != nil)
        probe("cullingMisses", cullingMisses)
        probe("subSteps", lastSubSteps)
        probe("kineticEnergy", Double(stage.rig.kineticEnergy))

        if let pit = stage as? PitStage { probe("pitRecycled", pit.recycleCount) }
        if let chain = stage as? ChainStage { probe("chainBobDepth", Double(chain.bobDepth)) }

        // 決定論的な検査の結果。毎フレーム同じ値が載る
        for verdict in verdicts { probe("check.\(verdict.id)", verdict.line) }
        probe("summary.total", verdicts.count)
        probe("summary.passed", verdicts.filter(\.passed).count)
        probe("summary.failed", verdicts.filter { !$0.passed }.count)
    }

    // MARK: - 撮影

    /// `MARIONETTE_SHOTS=1` のとき、各場面が落ち着いた頃に 1 枚だけ書き出す。
    /// 場面ごとの絵を人手を介さず確かめるための口（`saveFrame` の検証も兼ねる）。
    ///
    /// 保存先は選べない: `saveFrame(_:)` は渡した名前に無条件で `~/Desktop/` を前置するため、
    /// 絶対パスを渡すと存在しない階層になり、**何も保存されないまま無言で終わる**。
    /// ここではファイル名だけを渡し、デスクトップに出たものを呼び出し側が回収する。
    private func saveShotIfRequested(_ stage: Stage, elapsed: Float) {
        guard ProcessInfo.processInfo.environment["MARIONETTE_SHOTS"] != nil,
              elapsed > 8, !shotsTaken.contains(stage.name)
        else { return }
        shotsTaken.insert(stage.name)
        let name = "marionette-\(stage.name).png"
        saveFrame(name)
        print("[shot] \(stage.name) → ~/Desktop/\(name)")
        fflush(stdout)
    }

    private var shotsTaken: Set<String> = []

    /// `MARIONETTE_FRAMES=<dir>` のとき、指定した場面の 4 秒ぶんを連番 PNG で書き出す。
    /// GIF は別途 ffmpeg で組む（動きが主題の場面を記録に残すため）。
    /// `beginFrameRecord(directory:)` は `saveFrame` と違って絶対パスを尊重する。
    private func recordFramesIfRequested(_ stage: Stage, elapsed: Float) {
        guard let directory = ProcessInfo.processInfo.environment["MARIONETTE_FRAMES"] else { return }
        let target = ProcessInfo.processInfo.environment["MARIONETTE_FRAMES_STAGE"] ?? "chain"
        guard stage.name == target else { return }

        if !framesRecording, !framesDone, elapsed > 6 {
            framesRecording = true
            beginFrameRecord(directory: directory)
            print("[frames] 記録開始 → \(directory)")
            fflush(stdout)
        } else if framesRecording, elapsed > 10 {
            endFrameRecord()
            framesRecording = false
            framesDone = true
            print("[frames] 記録終了")
            fflush(stdout)
        }
    }

    private var framesRecording = false
    private var framesDone = false

    // MARK: - 操作

    func keyPressed() {
        guard let key else { return }
        switch key {
        case "1"..."4":
            if let index = Int(String(key)) { go(to: index - 1) }
        case " ":
            autoAdvance.toggle()
        case "l":
            showLinks.toggle()
        case "h":
            showHUD.toggle()
        case "c":
            cullingEnabled.toggle()
        default:
            break
        }
    }
}
