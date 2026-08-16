import Foundation
import metaphor

// 0816-emulsion — 乳剤。暗室の重ね焼き。
//
// 2D の版（`Graphics`）と 3D の被写体（`Graphics3D`）を**別々の感光層に焼き**、
// `MergePass` で 1 枚の印画紙に重ねる。焼き方を変えると同じ 2 層が別の写真になる。
//
// 「2D と 3D が混在する」を、同じフレームに混ぜるのではなく
// **別々に焼いてから重ねる**方向で扱うのがこの作品の立ち位置。
// 混ぜる方（同一フレーム内の交錯）は場面 4 が引き受ける。
//
// 検証記録: https://github.com/shinyaoguri/metaphor-sketches/issues/19

@main
final class Sketch0816Emulsion: Sketch {
    var config: SketchConfig {
        SketchConfig(width: 1280, height: 720, title: "0816-emulsion")
    }

    // MARK: - 場面

    enum Scene: Int, CaseIterable {
        case plate      // 版下 — グラフを外し、2 枚の層を並べて見せる
        case superimpose // 重ね焼き — グラフ有り。ブレンドを巡る
        case branch     // 分岐 — グラフ有り。版を 2 経路へ分け、片方だけ反転する
        case seam       // 交錯 — グラフを外し、1 フレームに 2D と 3D を混ぜる

        var title: String {
            switch self {
            case .plate: return "版下 Plate — 2 枚の層"
            case .superimpose: return "重ね焼き Superimpose — MergePass"
            case .branch: return "分岐 Branch — DAG と EffectPass"
            case .seam: return "交錯 Seam — 1 フレームに 2D と 3D"
            }
        }

        var caption: String {
            switch self {
            case .plate:
                return "左が 2D の版 (createGraphics)、右が 3D の被写体 (createGraphics3D)。この 2 枚が以降すべての入力"
            case .superimpose:
                return "同じ 2 層を .add / .alpha / .multiply / .screen で焼き直す。blendType は実行中に差し替えている"
            case .branch:
                return "版が 2 本の経路へ分かれ、片方だけ InvertEffect を通る。版 × 版のネガ = 中間調だけが残る"
            case .seam:
                return "グラフを外す。2D 層は透明を持つので下地が透け、3D 層は不透明な黒で下地を切り抜く（L3）"
            }
        }
    }

    /// 1 場面の長さ（フレーム）。60fps で 15 秒。4 場面で 1 巡 60 秒。
    static let sceneFrames = 900
    /// `shots` のときだけ縮める。4 場面そろうまで待つので、巡回が長いと撮り終わらない。
    /// 場面 2 は 4 つのブレンドを巡るので、4 で割り切れる長さにしておく。
    static let shotsSceneFrames = 240

    // MARK: - 状態

    private var layers: Layers!
    private var room: Darkroom0!
    private var darkroom: Darkroom!

    /// 検査フェーズが終わったフレーム。以降が本編。
    private var artStartFrame: Int?
    /// 現在の場面。`draw()` の先頭で更新する。
    private var scene: Scene = .plate
    /// いま画面に載っているグラフ。同じものを毎フレーム set し直さないための覚え。
    private var activeGraph: ObjectIdentifier?

    // 観測の口
    private let wantShots = ProcessInfo.processInfo.environment["EMULSION_SHOTS"] == "1"
    private let wantTrace = ProcessInfo.processInfo.environment["EMULSION_TRACE"] == "1"
    private let framesDir = ProcessInfo.processInfo.environment["EMULSION_FRAMES"]
    private let trapName = ProcessInfo.processInfo.environment["EMULSION_TRAP"]
    /// 場面を 1 つに固定する。証跡を撮るときに巡回を待たなくて済む
    /// （`EMULSION_SCENE=0`〜`3`）。
    private let pinnedScene = ProcessInfo.processInfo.environment["EMULSION_SCENE"].flatMap(Int.init)

    /// `shots` で撮り終えた場面の数。
    private var shotsTaken = 0
    private var shotsGrace = 0
    private var recording = false
    private var armedTrap: Trap?

    /// 場面の長さを外から縮める（`EMULSION_SCENE_FRAMES`）。
    /// GIF を撮るときに使う。既定の 15 秒だと、場面 2 の 4 ブレンドを 1 巡させるだけで
    /// 15 秒ぶんのフレームが必要になり、GIF に収まらない。
    private let sceneFramesOverride = ProcessInfo.processInfo
        .environment["EMULSION_SCENE_FRAMES"].flatMap(Int.init)

    /// この実行での 1 場面の長さ。
    private var sceneFrames: Int {
        sceneFramesOverride ?? (wantShots ? Self.shotsSceneFrames : Self.sceneFrames)
    }

    // MARK: - setup

    func setup() {
        frameRate(60)

        guard let l = Layers(sketch: self, width: Int(width), height: Int(height)) else {
            Emulsion.say("!! Layers の確保に失敗した（createGraphics / createGraphics3D が nil）")
            exit(1)
        }
        layers = l

        guard let r = Darkroom0(sketch: self, layers: l) else {
            Emulsion.say("!! RenderGraph の組み立てに失敗した（createMergePass / createEffectPass が nil）")
            exit(1)
        }
        room = r

        darkroom = Darkroom(sketch: self)

        // 落ちうる口は頼まれたときだけ踏む。常時実行すると作品が起動しなくなる
        // （#10 の学び: v0.9.0 の `step(dt, iterations: -1)` で起動不能になった）。
        if let name = trapName {
            armedTrap = Trap.arm(name, sketch: self)
            if armedTrap == nil { exit(0) }
            return   // 検査もフレーム記録も要らない。trap だけを回す
        }

        // 描画も時計も使わない検査はここで済ませる。
        darkroom.runOfflineChecks()

        if let dir = framesDir {
            beginFrameRecord(directory: dir)
            recording = true
        }
    }

    // MARK: - draw

    func draw() {
        let f = frameCount

        // trap を仕掛けたときは、**数フレーム回してから**読み戻して終わる。
        // 組めたかどうかは証拠にならない（グラフはフレームを回して初めて実行される）。
        if let trap = armedTrap {
            if f >= 20 {
                trap.report()
                Emulsion.say("trap 完了")
                exit(0)
            }
            return
        }

        // ── 検査フェーズ（テストストリップ）──────────────────────────
        // グラフを通した検査は、レンダラーにグラフを実行させないと結果が出ない。
        // 本編の前に短い露光テストとして走らせる。暗室の作法そのものでもある。
        if artStartFrame == nil {
            if darkroom.stepGraphChecks(frame: f, room: room, layers: layers) {
                artStartFrame = f + 1
                darkroom.finish()
            }
            return
        }

        let elapsed = f - artStartFrame!
        let index = pinnedScene.map { $0 % Scene.allCases.count }
            ?? (elapsed / self.sceneFrames) % Scene.allCases.count
        scene = Scene(rawValue: index)!
        let within = elapsed % self.sceneFrames

        // 層はどの場面でも焼く。場面ごとに焼いたり止めたりすると
        // GPU の仕事量が場面で変わり、ソークの読みが濁る。
        layers.exposePlate(frame: f)
        layers.exposeSubject(frame: f)

        switch scene {
        case .plate:  drawPlateScene()
        case .superimpose: drawSuperimposeScene(within: within)
        case .branch: drawBranchScene()
        case .seam:   drawSeamScene(frame: f)
        }

        probe("scene", scene.title)
        probe("check.tally", darkroom.tally)
        if wantTrace && f % 30 == 0 {
            Emulsion.say("[trace] frame=\(f) scene=\(scene) \(darkroom.tally)")
        }

        // `shots` は場面ごとに 1 枚。撮る位置は場面で変える。
        // 場面 2 は 4 つのブレンドを巡るので、真ん中で撮ると `.multiply` に当たる。
        // 透明な版に `.multiply` を掛けるとほぼ黒になる（透明画素の rgb が 0 だから）
        // ので、索引のサムネとしては場面を代表しない。`.screen` の巡で撮る。
        let shotAt = scene == .superimpose ? self.sceneFrames / 8 : self.sceneFrames / 2
        if wantShots && within == shotAt {
            // `saveFrame(_:)` は渡した名前に無条件で ~/Desktop を前置する
            // （metaphor#757）。出力先はここでは選べない。
            saveFrame("emulsion-\(index)-\(scene).png")
            shotsTaken += 1
        }
        // **最後の 1 枚を撮った直後に exit すると、その 1 枚だけ書き出されない。**
        // `saveFrame` は非同期に書き出すので、猶予フレームを置いてから落とす
        // （最初これで 4 枚目が落ちた）。
        if wantShots && shotsTaken >= Scene.allCases.count {
            shotsGrace += 1
            if shotsGrace > 30 {
                Emulsion.say("shots 完了")
                exit(0)
            }
        }
    }

    // MARK: - 場面 1 版下

    private func drawPlateScene() {
        useGraph(nil)
        background(8, 10, 14)

        let half = width / 2
        let inset: Float = 24
        // `image(_ pg: Graphics, …)` と `image(_ pg: Graphics3D, …)` の両方を通す。
        // 2D 層と 3D 層を**同じ呼び方で**貼れるかどうかがここで分かる。
        image(layers.plate, inset, inset, half - inset * 1.5, height - inset * 2 - 118)
        image(layers.subject, half + inset * 0.5, inset, half - inset * 1.5, height - inset * 2 - 118)

        noFill()
        stroke(90, 130, 150, (0.6) * 255)
        strokeWeight(1)
        rect(inset, inset, half - inset * 1.5, height - inset * 2 - 118)
        rect(half + inset * 0.5, inset, half - inset * 1.5, height - inset * 2 - 118)

        noStroke()
        fill(150, 200, 225, (0.85) * 255)
        textSize(13)
        text("2D — createGraphics", inset + 8, inset + 20)
        text("3D — createGraphics3D", half + inset * 0.5 + 8, inset + 20)

        drawCritiqueBar()
    }

    // MARK: - 場面 2 重ね焼き

    private static let blendCycle: [MergePass.BlendType] = [.screen, .add, .multiply, .alpha]

    private func drawSuperimposeScene(within: Int) {
        // 1 場面のあいだに 4 通りを巡る。`blendType` の実行時差し替えが
        // そのまま作品の動きになる（`M6`）。
        let slot = (within / (self.sceneFrames / Self.blendCycle.count)) % Self.blendCycle.count
        let blend = Self.blendCycle[slot]
        room.superimpose.blendType = blend

        // `.alpha` の巡だけ絵が壊れて見えるが、これは失敗ではなく**この作品が
        // 見つけたこと**。3D の層は `background()` を持たず下地が不透明の黒で
        // 固定されるので（判定 `L3`）、前景に置くと下の版が丸ごと消える。
        // 隠さずにそのまま出して、欄外に理由を書く。
        let note: String
        switch blend {
        case .alpha:
            note = "いま .alpha — 3D 層の下地が不透明な黒なので、下の版が消える（L3）"
        case .multiply:
            // 透明な画素は premultiplied なので rgb=0。0 を掛ければ 0。
            // 焼き込みすぎた印画紙に見えるが、合成の定義どおりの結果。
            note = "いま .multiply — 透明な画素は rgb=0 なので、掛けると黒く沈む"
        default:
            note = "いま焼いているブレンド: .\(blend.rawValue)"
        }
        layers.exposeHUD(
            title: scene.title,
            caption: scene.caption,
            tally: darkroom.tally,
            allPassed: darkroom.allPassed,
            lines: [note] + darkroom.headlines
        )
        useGraph(room.superimposeGraph)
        probe("merge.blendType", blend.rawValue)
    }

    // MARK: - 場面 3 分岐

    private func drawBranchScene() {
        layers.exposeHUD(
            title: scene.title,
            caption: scene.caption,
            tally: darkroom.tally,
            allPassed: darkroom.allPassed,
            lines: ["plate → (素) と (InvertEffect) の 2 経路"] + darkroom.headlines
        )
        useGraph(room.branchGraph)
    }

    // MARK: - 場面 4 交錯

    private func drawSeamScene(frame: Int) {
        useGraph(nil)
        background(8, 10, 14)

        let stage = height - 118

        // (1) 直描きの 2D — 下地。**全面に敷く**ので、この後に貼るものが
        //     どこまで下地を隠すかがそのまま見える
        noStroke()
        for i in 0..<40 {
            let x = Emulsion.hash(i, 11) * width
            let y = Emulsion.hash(i, 12) * stage
            fill(60, 110, 140, (0.25 + Emulsion.hash(i, 13) * 0.3) * 255)
            circle(x, y, 20 + Emulsion.hash(i, 14) * 90)
        }

        // (2) 2D の層を貼る — 透明な下地を持つので、丸が透けて見える
        image(layers.plate, 40, 60, stage * 0.72, stage * 0.72)

        // (3) 3D の層を貼る（`image(_ pg: Graphics3D, …)`）
        //     **全面ではなく枠に収める。** 3D 層の下地は不透明な黒で固定されていて
        //     （判定 `L3`）、全面に貼ると下の 2D が丸ごと消える。
        //     枠にすることで「黒い矩形が下地を切り抜く」形がそのまま見え、
        //     (2) の 2D 層との違いが 1 画面で並ぶ。
        let panel: Float = stage * 0.62
        image(layers.subject, width * 0.40, stage * 0.14, panel, panel)
        noFill()
        stroke(120, 160, 185, (0.7) * 255)
        strokeWeight(1)
        rect(width * 0.40, stage * 0.14, panel, panel)

        // (4) 直描きの 3D — メインキャンバスへ直接
        let spin = Float(frame) * 0.011
        let z = ((height - 118) / 2) / tan(Float.pi / 6)
        perspective(fov: .pi / 3, near: 0.1, far: 10000)
        camera(eye: SIMD3(width / 2, (height - 118) / 2, z),
               center: SIMD3(width / 2, (height - 118) / 2, 0),
               up: SIMD3(0, 1, 0))
        ambientLight(0.2)
        directionalLight(-0.4, -0.7, -0.6)
        pushMatrix()
        translate(width * 0.86, stage * 0.30, 0)
        rotateY(spin * 1.6)
        rotateX(0.5)
        fill(Color(SIMD4(0.95, 0.55, 0.30, 1)))
        box(88)
        popMatrix()

        // (5) また直描きの 2D — 3D の上に出るか（`X2`）
        //
        // **ここに loadPixels() が 1 行要る。** 検査で分かったとおり、
        // 同じフレームでは呼んだ順に関わらず 3D が 2D の上に塗られる（`X5`）ので、
        // この帯と文字は箱に隠れる。`loadPixels()` はレンダーパスを分割するため、
        // 挟むと以降の 2D が 3D の後ろのパスに入って上に出る（`X6`）。
        // 作品の都合ではなく、混在フレームで HUD を出すための唯一の道。
        loadPixels()

        // 箱を横切る白い帯。**loadPixels() の前だとこれが箱に隠れる。**
        // 帯が箱の上に見えているなら、パス分割が効いているということ。
        noStroke()
        fill(240, 245, 250, (0.92) * 255)
        rect(width * 0.86 - 90, stage * 0.30 - 4, 180, 8)

        fill(150, 200, 225, (0.9) * 255)
        textSize(13)
        text("直描き 2D（下地）", 44, 48)
        text("image(pg: Graphics) — 透明な下地を持つので丸が透ける", 44, stage * 0.72 + 84)
        text("image(pg: Graphics3D) — 下地が不透明な黒なので下を切り抜く", width * 0.40, stage * 0.14 - 10)
        textAlign(.right)
        text("直描き 3D + loadPixels() 後の 2D", width - 30, stage * 0.30 - 26)
        textAlign(.left)

        drawCritiqueBar()
    }

    // MARK: - 共通

    /// グラフ無しの場面で使う講評欄。中身は `Layers.exposeHUD` と同じ趣旨だが、
    /// こちらはメインキャンバスへ直接描ける。
    private func drawCritiqueBar() {
        let barH: Float = 118
        noStroke()
        fill(6, 9, 14, (0.72) * 255)
        rect(0, height - barH, width, barH)
        fill(150, 220, 240, (0.5) * 255)
        rect(0, height - barH, width, 1)

        fill(235, 244, 250, (0.95) * 255)
        textSize(19)
        text(scene.title, 26, height - barH + 30)

        fill(168, 196, 214, (0.9) * 255)
        textSize(13)
        text(scene.caption, 26, height - barH + 54)

        textSize(13)
        fill(darkroom.allPassed ? Color(SIMD4(0.62, 0.85, 0.66, 0.95))
                                : Color(SIMD4(0.94, 0.42, 0.36, 0.98)))
        text(darkroom.tally, 26, height - barH + 78)

        textSize(12)
        fill(196, 210, 222, (0.85) * 255)
        var y = height - barH + 78
        for line in darkroom.headlines.prefix(3) {
            text(line, 300, y)
            y += 16
        }

        textAlign(.right)
        fill(120, 150, 170, (0.8) * 255)
        textSize(12)
        text("0816-emulsion", width - 26, height - barH + 30)
        textAlign(.left)
    }

    /// グラフを差し替える。同じものを毎フレーム set し直さない。
    private func useGraph(_ graph: RenderGraph?) {
        let id = graph.map { ObjectIdentifier($0) }
        guard id != activeGraph else { return }
        setRenderGraph(graph)
        activeGraph = id
    }

    // MARK: - Darkroom から使う内部の口

    /// 検査フェーズのあいだだけ、検査用のグラフを画面に出す。
    func showCheckGraph(_ graph: RenderGraph?) {
        useGraph(graph)
    }
}
