import Foundation
import metaphor

/// 区間の所要時間をミリ秒で測る（probe で観測するための一時計測）。
@inline(__always)
private func measure(_ body: () -> Void) -> Float {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Float(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

/// 三次元ライフゲーム — 暗闇に浮かぶ立方体の培養槽の中で、細胞群が生まれては消える。
///
/// 生死そのものは離散的なステップだが、表示は強度を補間して滑らかに明滅させている。
/// 群体が停滞・絶滅したら自動で蒔き直すので、放置しても絵が止まらない。
@main
final class Sketch0815Lifegame: Sketch {
    var config: SketchConfig {
        SketchConfig(width: 1280, height: 720, title: "0815-lifegame", preserveClock: true)
    }

    // MARK: - 調整できる値（再ビルドなしで変更できる）

    @Param(choices: LifeRule.names) var rule: String = "pyroclastic"
    @Param(min: 12, max: 40) var gridSize: Int = 24
    @Param(min: 0.02, max: 1.0) var stepInterval: Float = 0.12
    // 初期値は既定ルール pyroclastic のもの。ルールを切り替えると、そのルールの既定へ揃えて蒔き直す
    @Param(min: 0.05, max: 1.0) var seedDensity: Float = 0.30
    @Param(min: 0.1, max: 1.0) var seedSpan: Float = 0.35
    @Param(min: 0.2, max: 1.0) var cellScale: Float = 0.78
    @Param(min: -0.8, max: 0.8) var autoRotate: Float = 0.14
    @Param(min: 0.6, max: 2.0) var zoom: Float = 1.2
    /// 群体の内側（26 近傍がすべて生存）を描かない。密なルールでは描画量が桁で減る。
    @Param var shellOnly: Bool = true
    /// 境界を巻き込む（トーラス）。切ると壁際の細胞が削られ、群体は痩せて消えやすくなる。
    @Param var wrapEdges: Bool = true
    @Param(min: 0.0, max: 2.5) var bloomIntensity: Float = 1.8
    @Param(min: 0.1, max: 1.0) var bloomThreshold: Float = 0.32
    @Param var showCage: Bool = true
    @Param var showHUD: Bool = true
    @Param var paused: Bool = false

    // MARK: - 内部状態

    private var life = Life3D(size: 24, rule: LifeRule.named("pyroclastic"))
    private var cube: Mesh!
    private var bloom: BloomEffect!

    /// 培養槽の一辺（ワールド単位 = ピクセル）。格子サイズが変わってもこの大きさは保つ。
    private let worldSize: Float = 520

    private var accumulator: Float = 0
    /// 停滞を検知してから蒔き直すまでの猶予（演出のための間）。
    private var reseedAt: Float?

    private var autoYaw: Float = 0
    private var yaw: Float = 0
    private var pitch: Float = -0.32
    private var mouseHasMoved = false
    private var smoothedFPS: Float = 60

    private var transforms: [float4x4] = []
    private var colors: [Color] = []
    /// 背景の星（x, y, 基準の明るさ）。setup で一度だけ配置する。
    private var stars: [SIMD3<Float>] = []
    private var starInstances: [CircleInstance] = []

    // 一時的な計測値（probe に出して重い箇所を突き止める）
    private var msStep: Float = 0
    private var msIntensity: Float = 0
    private var msCells: Float = 0
    private var msCage: Float = 0
    private var msHUD: Float = 0

    func setup() {
        frameRate(60)
        noStroke()

        // サイズ 1 の立方体を 1 つだけ作り、インスタンスごとの行列で拡大する
        // （格子サイズを変えてもメッシュを作り直さなくてよい）
        guard let mesh = createBoxMesh(1) else {
            fatalError("キューブメッシュを作れませんでした")
        }
        cube = mesh

        life.seed(density: seedDensity, span: seedSpan)

        bloom = BloomEffect(intensity: bloomIntensity, threshold: bloomThreshold)
        addPostEffect(bloom)

        transforms.reserveCapacity(life.cellCount)
        colors.reserveCapacity(life.cellCount)

        // 背景の星。位置は固定で、明るさだけを draw でゆらす
        for _ in 0..<220 {
            stars.append(SIMD3(
                Float.random(in: 0...Float(config.width)),
                Float.random(in: 0...Float(config.height)),
                Float.random(in: 0.15...1.0)
            ))
        }
        starInstances.reserveCapacity(stars.count)
    }

    func draw() {
        background(4, 7, 12)
        drawStars()

        updateSimulation()
        updateCamera()

        bloom.intensity = bloomIntensity
        bloom.threshold = bloomThreshold

        ambientLight(150)
        directionalLight(-0.35, 0.8, -0.45)

        push()
        // 既定カメラ（ピクセル空間）は原点から約 623px 手前にある。培養槽の対角が画面に収まる距離まで奥へ置く
        translate(width * 0.56, height / 2, -worldSize / max(zoom, 0.1))
        rotateX(pitch)
        rotateY(yaw)
        msCage = measure { if showCage { drawCage() } }
        msCells = measure { drawCells() }
        pop()

        msHUD = measure { if showHUD { drawHUD() } }
        reportProbes()
    }

    // MARK: - シミュレーション

    private func updateSimulation() {
        life.wrap = wrapEdges
        // 解決後の名前で比べる。保存済みパラメータに未知のルール名が残っていると
        // LifeRule.named が既定へフォールバックし、名前が一致しないまま毎フレーム
        // 蒔き直し続けてしまうため、解決結果を rule へ書き戻して自己修復する。
        let next = LifeRule.named(rule)
        if next.name != life.rule.name {
            // ルールごとに育ちやすい初期条件が違うので、切り替えたら既定値へ揃えて蒔き直す
            life.rule = next
            seedDensity = next.seedDensity
            seedSpan = next.seedSpan
            reseed()
        }
        if rule != next.name { rule = next.name }
        if gridSize != life.size {
            life.resize(to: gridSize, density: seedDensity, span: seedSpan)
            accumulator = 0
            reseedAt = nil
        }

        if let at = reseedAt {
            if time >= at {
                reseed()
            }
        } else if !paused {
            let interval = max(0.02, stepInterval)
            accumulator += deltaTime
            // 1 フレームで詰め込みすぎないよう上限を設ける
            var steps = 0
            msStep = 0
            while accumulator >= interval && steps < 4 {
                accumulator -= interval
                msStep += measure { life.step() }
                steps += 1
                if life.isStagnant {
                    reseedAt = time + 0.9
                    accumulator = 0
                    break
                }
            }
        }

        msIntensity = measure { life.updateIntensity(deltaTime: deltaTime) }

        let fps = deltaTime > 0 ? 1 / deltaTime : smoothedFPS
        smoothedFPS += (fps - smoothedFPS) * 0.06
    }

    private func reseed() {
        life.seed(density: seedDensity, span: seedSpan)
        life.markReseeded()
        reseedAt = nil
        accumulator = 0
    }

    private func updateCamera() {
        autoYaw += autoRotate * deltaTime
        if mouseX != pmouseX || mouseY != pmouseY { mouseHasMoved = true }

        var targetYaw = autoYaw
        var targetPitch: Float = -0.32
        if mouseHasMoved {
            targetYaw += (mouseX / max(width, 1) - 0.5) * 1.8
            targetPitch += (mouseY / max(height, 1) - 0.5) * -1.0
        }
        // 目標へゆっくり寄せる（マウスを動かしても画がガタつかない）
        yaw += (targetYaw - yaw) * min(1, deltaTime * 4)
        pitch += (targetPitch - pitch) * min(1, deltaTime * 4)
    }

    // MARK: - 描画

    private func drawCells() {
        let n = life.size
        let unit = worldSize / Float(n)
        let half = Float(n - 1) / 2
        let base = unit * cellScale
        let invRadius = 1 / max(half * 1.15, 0.001)

        // 視点から見た奥行きで暗くする（回転後の z 成分だけを手前で求めておく）
        let sy = sin(yaw), cy = cos(yaw)
        let sp = sin(pitch), cp = cos(pitch)
        let depthRange = max(half * 1.74, 0.001)

        transforms.removeAll(keepingCapacity: true)
        colors.removeAll(keepingCapacity: true)

        for z in 0..<n {
            let dz = Float(z) - half
            for y in 0..<n {
                let dy = Float(y) - half
                let layer = Float(y) / Float(max(n - 1, 1))
                for x in 0..<n {
                    let i = (z * n + y) * n + x
                    let v = life.intensity[i]
                    if v < 0.03 { continue }
                    // 群体の内側は外から見えないので描かない（密なルールでは大半がこれ）
                    if shellOnly && life.isInterior(i) { continue }

                    let dx = Float(x) - half
                    // なめらかに立ち上がる（smoothstep）。減衰中の細胞はさらに小さく、点に近づける
                    let e = v * v * (3 - 2 * v) * (life.cells[i] == 1 ? 1 : 0.62)
                    let position = SIMD3<Float>(dx * unit, -dy * unit, dz * unit)  // +y は画面下向き
                    transforms.append(
                        float4x4(translation: position) * float4x4(scale: base * e)
                    )
                    let radial = min(1, (dx * dx + dy * dy + dz * dz).squareRoot() * invRadius)
                    // 手前ほど明るく、奥ほど沈む
                    let viewZ = -dy * sp + (-dx * sy + dz * cy) * cp
                    let depth = max(0.34, min(1, 0.62 + 0.45 * (viewZ / depthRange)))
                    colors.append(cellColor(index: i, radial: radial, layer: layer, fade: v, depth: depth))
                }
            }
        }

        guard !transforms.isEmpty else { return }
        drawInstanced(cube, transforms: transforms, colors: colors)
    }

    /// 細胞の色。核に近いほどシアン、外縁ほど青紫。生まれた直後は白熱し、
    /// 長く生きた細胞は落ち着いて沈む。減衰中の細胞は紫の残光になる。
    private func cellColor(index: Int, radial: Float, layer: Float, fade: Float, depth: Float) -> Color {
        if life.cells[index] != 1 {
            // 減衰中の細胞。紫の残光が二乗で急速に沈み、群体の軌跡だけを残す
            let f = min(1, fade / 0.45)
            let g = f * f * depth
            return Color(r: (0.30 + 0.34 * f) * g, g: 0.07 * g, b: 0.78 * g)
        }

        let a = Float(life.age[index])
        var r = 0.06 + 0.36 * radial
        var g = 0.92 - 0.32 * radial
        var b = 1.00 - 0.04 * radial

        // 層でわずかな温度差をつけ、上下の見分けをつける
        r += (layer - 0.5) * 0.10
        b -= (layer - 0.5) * 0.14

        // 長寿の細胞は明度を落として奥に沈める
        let dim = (1 - 0.34 * min(1, a / 60)) * depth
        r *= dim; g *= dim; b *= dim

        // 生まれた直後だけ白熱させる（誕生が目で追える。強すぎると全体が白飛びする）
        let flash = max(0, 1 - a / 2.5) * 0.55
        r += (1 - r) * flash
        g += (1 - g) * flash
        b += (1 - b) * flash

        return Color(r: r, g: g, b: b)
    }

    /// 培養槽のワイヤーフレーム（12 辺 + 底面と天面の格子）。
    private func drawCage() {
        let h = worldSize / 2
        let corners: [SIMD3<Float>] = [
            SIMD3(-h, -h, -h), SIMD3(h, -h, -h), SIMD3(h, h, -h), SIMD3(-h, h, -h),
            SIMD3(-h, -h, h), SIMD3(h, -h, h), SIMD3(h, h, h), SIMD3(-h, h, h),
        ]
        let edges = [
            (0, 1), (1, 2), (2, 3), (3, 0),
            (4, 5), (5, 6), (6, 7), (7, 4),
            (0, 4), (1, 5), (2, 6), (3, 7),
        ]

        pushStyle()
        strokeWeight(1.2)
        stroke(60, 180, 230, 85)
        beginShape3D(.lines)
        for (a, b) in edges {
            vertex(corners[a].x, corners[a].y, corners[a].z)
            vertex(corners[b].x, corners[b].y, corners[b].z)
        }
        endShape3D()

        // 上下の面に薄い格子を敷いて、奥行きの手がかりにする
        stroke(45, 130, 180, 40)
        strokeWeight(1)
        beginShape3D(.lines)
        let divisions = 4
        for level in [-h, h] {
            for i in 0...divisions {
                let t = -h + worldSize * Float(i) / Float(divisions)
                vertex(t, level, -h); vertex(t, level, h)
                vertex(-h, level, t); vertex(h, level, t)
            }
        }
        endShape3D()
        popStyle()
    }

    /// 背景の星。一括描画なので 200 個でも 1 回の呼び出しで済む。
    private func drawStars() {
        starInstances.removeAll(keepingCapacity: true)
        for (i, s) in stars.enumerated() {
            // 星ごとに位相をずらして瞬かせる
            let twinkle = 0.75 + 0.25 * sin(time * 1.7 + Float(i) * 2.399)
            let level = s.z * twinkle
            starInstances.append(CircleInstance(
                x: s.x, y: s.y,
                diameter: 1 + s.z * 1.6,
                color: Color(r: 0.62 * level, g: 0.78 * level, b: level)
            ))
        }
        pushStyle()
        noStroke()
        circles(starInstances)
        popStyle()
    }

    // MARK: - HUD（観測装置の計器）

    private func drawHUD() {
        pushStyle()
        noStroke()
        textFont("Menlo")

        let x: Float = 30
        textSize(13)
        fill(130, 240, 255)
        text("SPECIMEN // 3D-LIFE", x, 42)

        textSize(11)
        fill(80, 160, 200)
        let ratio = Float(life.population) / Float(max(life.cellCount, 1))
        let rows = [
            "RULE      \(life.rule.name.uppercased())   \(life.rule.summary)",
            String(format: "GEN       %05d", life.generation),
            String(format: "POP       %05d  (%.2f%%)", life.population, ratio * 100),
            String(format: "FLUX      +%d / -%d", life.births, life.deaths),
            "LATTICE   \(life.size)³ = \(life.cellCount)  \(wrapEdges ? "TORUS" : "SEALED")",
            String(format: "CYCLES    %d", life.reseedCount),
        ]
        for (i, row) in rows.enumerated() {
            text(row, x, 68 + Float(i) * 17)
        }

        // 個体数のバー
        let barW: Float = 190
        let barY: Float = 68 + Float(rows.count) * 17 + 6
        fill(40, 80, 105)
        rect(x, barY, barW, 3)
        fill(120, 235, 255)
        rect(x, barY, barW * min(1, ratio * 8), 3)

        // 状態表示
        textSize(11)
        if reseedAt != nil {
            // 蒔き直しの直前だけ点滅させる
            let blink = sin(time * 18) > 0
            fill(255, blink ? 120 : 40, 90)
            text("⟡ CULTURE COLLAPSED — RESEEDING", x, barY + 26)
        } else if paused {
            fill(255, 190, 90)
            text("⏸ SUSPENDED", x, barY + 26)
        } else {
            fill(60, 120, 150)
            text(String(format: "STEP %.0f ms", max(0.02, stepInterval) * 1000), x, barY + 26)
        }

        // 右下の計器
        textAlign(.right)
        fill(60, 120, 150)
        textSize(10)
        text(String(format: "%.0f FPS", smoothedFPS), width - 30, height - 46)
        text("SPACE pause   R reseed   N step   mouse to orbit", width - 30, height - 30)
        textAlign(.left)

        // 画面枠の飾り罫
        stroke(50, 130, 180, 70)
        strokeWeight(1)
        line(24, 22, 24, height - 22)
        line(24, 22, 300, 22)
        line(width - 24, 22, width - 24, height - 22)
        line(width - 300, height - 22, width - 24, height - 22)
        popStyle()
    }

    private func reportProbes() {
        probe("life.rule", life.rule.name)
        probe("life.generation", life.generation)
        probe("life.population", life.population)
        probe("life.births", life.births)
        probe("life.deaths", life.deaths)
        probe("life.instances", transforms.count)
        probe("life.reseeds", life.reseedCount)
        probe("life.paused", paused)
        probe("ms.step", msStep)
        probe("ms.intensity", msIntensity)
        probe("ms.cells", msCells)
        probe("ms.cage", msCage)
        probe("ms.hud", msHUD)
    }

    // MARK: - 入力

    func keyPressed() {
        guard let k = key else { return }
        switch k {
        case " ":
            paused.toggle()
        case "r", "R":
            reseed()
        case "n", "N":
            life.step()
        default:
            break
        }
    }

    // MARK: - リロードを跨いで培養を続ける

    func saveState() -> Data? {
        encodeState(life.snapshotState())
    }

    func restoreState(_ data: Data) {
        guard let saved: Life3D.Saved = decodeState(data) else { return }
        life.restore(saved)
        gridSize = saved.size
    }
}
