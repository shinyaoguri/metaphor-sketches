import Foundation
import metaphor
import simd

extension Color {
    /// 0..255 の 3 成分から作る。
    ///
    /// `fill` は 0..255 の 3 引数を受けるのに `emissive` は `Color`（0..1）か
    /// グレースケールしか受けない。同じ感覚で書けないので作品側で埋める。
    static func rgb255(_ v: SIMD3<Float>) -> Color {
        Color(r: v.x / 255, g: v.y / 255, b: v.z / 255)
    }
}

/// シーンの 1 フレーム分の文脈。
///
/// `sketch` を毎フレーム渡すのは、metaphor の描画 API（`fill` / `mesh` / `camera` …）が
/// `Sketch` プロトコル拡張として生えているため。シーン側に `Sketch` を保持させると
/// 循環参照になるので、struct で渡し切る。
struct SceneContext {
    let sketch: any Sketch
    let shared: SharedAssets
    let ledger: AssetLedger
    let input: InputState
    let dt: Float
    let time: Float
    let width: Float
    let height: Float
    let demo: Bool
}

/// 次にどのシーンへ行きたいか、というシーンからの要求。
enum SceneRequest: Equatable {
    case title
    case stage(Int)
    case result(success: Bool, collected: Int, reached: Int)
}

/// **[#571](https://github.com/shinyaoguri/metaphor/issues/571) の叩き台を作品側で書いてみたもの。**
///
/// 案 A（protocol だけ・cleanup は作者が exit に書く）ではなく、案 B の限定版
/// （scope に預けたものだけ自動で片付く）にした。理由は `StageAssets` の解放が
/// 「参照を捨てる」だけでは済まない（音と動画は明示的に stop が要る）ため。
/// exit() を書き忘れても scope が持っていれば止まる、という形にしたかった。
@MainActor
final class SceneScope {
    private var teardowns: [() -> Void] = []
    private var timers: [(interval: Float, accumulated: Float, block: () -> Void)] = []

    /// ステージのアセット束を預ける。シーン退出時に `unload()` される。
    func own(_ assets: StageAssets) {
        teardowns.append { assets.unload() }
    }

    func onExit(_ block: @escaping () -> Void) {
        teardowns.append(block)
    }

    /// 周期タスク。scope に紐づくので、シーンを抜けたら止まる。
    func every(seconds: Float, _ block: @escaping () -> Void) {
        timers.append((seconds, 0, block))
    }

    func tick(dt: Float) {
        for i in timers.indices {
            timers[i].accumulated += dt
            if timers[i].accumulated >= timers[i].interval {
                timers[i].accumulated = 0
                timers[i].block()
            }
        }
    }

    func release() {
        for teardown in teardowns.reversed() { teardown() }
        teardowns.removeAll()
        timers.removeAll()
    }
}

@MainActor
protocol Scene: AnyObject {
    var id: String { get }
    /// シーンに入る。寿命を持つものは `scope` に預ける。
    func enter(_ scope: SceneScope, _ ctx: SceneContext)
    /// 状態を進め、遷移したいときは要求を返す。
    func update(_ ctx: SceneContext) -> SceneRequest?
    func draw(_ ctx: SceneContext)
    /// HUD に出す行（描画は App がまとめて行う）。
    var hudLines: [String] { get }
}

/// シーンの切り替えと寿命の管理。
@MainActor
final class SceneDirector {
    private(set) var current: any Scene
    private var scope = SceneScope()
    private let factory: (SceneRequest) -> any Scene
    private(set) var transitions = 0
    /// タイトルへ戻った回数（= 1 周）。ソークで周回数を数えるため。
    private(set) var cycles = 0

    init(initial: SceneRequest, ctx: SceneContext, factory: @escaping (SceneRequest) -> any Scene) {
        self.factory = factory
        self.current = factory(initial)
        self.current.enter(scope, ctx)
    }

    func go(to request: SceneRequest, ctx: SceneContext) {
        scope.release()
        scope = SceneScope()
        current = factory(request)
        current.enter(scope, ctx)
        transitions += 1
        if case .title = request { cycles += 1 }
    }

    func update(_ ctx: SceneContext) {
        scope.tick(dt: ctx.dt)
        if let request = current.update(ctx) {
            go(to: request, ctx: ctx)
        }
    }

    func draw(_ ctx: SceneContext) {
        current.draw(ctx)
    }
}

// MARK: - シーン実装

/// タイトル。**ステージ固有アセットを一切持たない**（共有アセットのみ）。
/// アセットが入れ替わる側との対照で、ここに入ると生存アセット数が共有分だけに戻る。
@MainActor
final class TitleScene: Scene {
    let id = "title"
    private var elapsed: Float = 0
    private var spin: Float = 0

    var hudLines: [String] { [] }

    func enter(_ scope: SceneScope, _ ctx: SceneContext) {
        elapsed = 0
    }

    func update(_ ctx: SceneContext) -> SceneRequest? {
        elapsed += ctx.dt
        spin += ctx.dt * 0.6
        // デモモードは無人で回す。人が操作するときは space 待ち。
        if ctx.demo && elapsed > 2.5 { return .stage(0) }
        if ctx.input.confirm && elapsed > 0.3 { return .stage(0) }
        return nil
    }

    func draw(_ ctx: SceneContext) {
        let s = ctx.sketch
        s.background(4, 9, 14)

        s.camera(eye: SIMD3(0, -180, 620), center: SIMD3(0, -40, 0))
        s.perspective(fov: .pi / 3.2, near: 1, far: 6000)
        s.ambientLight(110)
        s.directionalLight(-0.4, 0.7, -0.5, color: Color(r: 1.0, g: 0.95, b: 0.88))
        s.directionalLight(0.5, 0.2, 0.6, color: Color(r: 0.25, g: 0.42, b: 0.6))

        s.pbr(true)
        s.noStroke()

        if let drone = ctx.shared.drone {
            s.push()
            s.translate(0, -60 + sin(elapsed * 1.4) * 12, 0)
            s.rotateY(spin)
            s.rotateZ(0.18)
            s.scale(120)
            s.fill(196, 214, 224)
            // metallic を上げると沈む: metaphor の PBR は IBL を持たないため、
            // 金属の鏡面反射に返す環境が無く、拡散も失われて黒くなる（0.7 で灰色の塊になった）
            s.metallic(0.18)
            s.roughness(0.38)
            s.mesh(drone)
            s.pop()
        }

        if let beacon = ctx.shared.beacon {
            for i in 0..<3 {
                let a = spin * 0.4 + Float(i) * .pi * 2 / 3
                s.push()
                s.translate(cos(a) * 420, 40, sin(a) * 420 - 200)
                s.rotateY(-spin)
                s.scale(90)
                s.fill(46, 92, 104)
                s.metallic(0.12)
                s.roughness(0.62)
                s.mesh(beacon)
                s.pop()
            }
        }
    }
}

/// 1 ステージ分のプレイ。**このシーンだけがステージ固有アセットを持つ。**
@MainActor
final class PlayScene: Scene {
    /// `SALVAGE_PRIMITIVES=1` で、読み込んだ Mesh の代わりに組み込みプリミティブを描く。
    /// 「絵が想定と違う」ときライブラリ側とアセット側のどちらが原因か切り分けるための入口。
    static let usePrimitives = Env.bool("SALVAGE_PRIMITIVES")

    let id: String
    let spec: StageSpec
    let index: Int
    private let carriedLives: Int
    private let carriedCollected: Int

    private var assets: StageAssets?
    private var world: World!
    private var elapsed: Float = 0
    private var flash: Float = 0
    private var cameraEye = SIMD3<Float>(0, -420, 900)

    init(spec: StageSpec, index: Int, lives: Int, collected: Int) {
        self.id = spec.id
        self.spec = spec
        self.index = index
        self.carriedLives = lives
        self.carriedCollected = collected
    }

    var hudLines: [String] {
        guard let world else { return [] }
        return [
            "\(spec.label)   cores \(world.collected)/\(spec.coreCount)   lives \(world.lives)",
            String(format: "time %4.1f", world.timeLeft),
        ]
    }

    var totalCollected: Int { carriedCollected + (world?.collected ?? 0) }
    var livesLeft: Int { world?.lives ?? carriedLives }

    func enter(_ scope: SceneScope, _ ctx: SceneContext) {
        let assets = StageAssets(spec: spec, sketch: ctx.sketch, ledger: ctx.ledger)
        // 寿命を scope に預ける。シーンを抜ければ音も動画も止まり、参照も落ちる。
        scope.own(assets)
        assets.beginPlayback(volume: 0.5)
        self.assets = assets

        // シード = ステージ index。ソークで毎周同じ配置になり、再現性が保てる。
        world = World(spec: spec, seed: UInt64(0x5A1_7A6E + index * 977), lives: carriedLives)
        elapsed = 0
    }

    func update(_ ctx: SceneContext) -> SceneRequest? {
        elapsed += ctx.dt
        flash = max(0, flash - ctx.dt * 2.4)
        assets?.updatePlayback()

        let input = ctx.demo ? world.demoInput() : ctx.input
        world.update(dt: ctx.dt, input: input)

        for event in world.events {
            switch event {
            case .pickup:
                ctx.shared.pickup?.stop()
                ctx.shared.pickup?.play()
            case .hit:
                ctx.shared.hit?.stop()
                ctx.shared.hit?.play()
                flash = 1
            }
        }

        switch world.outcome {
        case .running:
            return nil
        case .cleared:
            let next = index + 1
            if next < StageSpec.all.count { return .stage(next) }
            return .result(success: true, collected: totalCollected, reached: next)
        case .failed:
            return .result(success: false, collected: totalCollected, reached: index)
        }
    }

    func draw(_ ctx: SceneContext) {
        let s = ctx.sketch
        s.background(spec.background.x, spec.background.y, spec.background.z)

        drawSky(ctx)
        drawBackdrop(ctx)
        setCamera(ctx)
        setLights(ctx)

        s.pbr(true)
        s.noStroke()

        drawFloor(ctx)
        drawObstacles(ctx)
        drawCores(ctx)
        drawBeacon(ctx)
        drawPlayer(ctx)
    }

    /// 遠景。3D の中に霧や空を置く手段が無いので、2D のグラデーションを先に敷く。
    private func drawSky(_ ctx: SceneContext) {
        let s = ctx.sketch
        s.push()
        s.resetMatrix()
        s.noStroke()
        s.linearGradient(
            0, 0, ctx.width, ctx.height,
            Color.rgb255(spec.fogTint * 0.9),
            Color.rgb255(spec.background),
            axis: .vertical)
        s.pop()
    }

    /// 背景動画。3D 空間へテクスチャとして貼る経路が無いので、2D として先に描く。
    private func drawBackdrop(_ ctx: SceneContext) {
        guard let backdrop = assets?.backdrop, backdrop.isAvailable else { return }
        let s = ctx.sketch
        s.push()
        s.resetMatrix()
        s.tint(255, 255, 255, 150)
        s.image(backdrop, 0, 0, ctx.width, ctx.height)
        s.noTint()
        s.pop()
    }

    /// `SALVAGE_NO_CAMERA=1` で camera()/perspective() を呼ばない（既定投影のまま）。
    /// enableShadows() が効かない原因の切り分け用。
    static let skipCamera = Env.bool("SALVAGE_NO_CAMERA")
    /// キーライト 1 灯 + 低 ambient に落とす（影の見え方の切り分け）。
    static let keyLightOnly = Env.bool("SALVAGE_KEY_LIGHT_ONLY")
    /// 影が出ない原因の切り分け: 床のテクスチャを外す（テクスチャ付きパイプラインを疑う）。
    static let shadowDebug = Env.bool("SALVAGE_SHADOW_DEBUG")

    private func setCamera(_ ctx: SceneContext) {
        guard !PlayScene.skipCamera else { return }
        let s = ctx.sketch
        // プレイヤーの真後ろ上空から、遅れて追う（カメラは回さないので酔わない）。
        // 高さは -Y 方向（metaphor の 3D は +Y が画面下）。
        let p = world.player.pos
        let target = SIMD3<Float>(p.x, p.y - 520, p.z + 820)
        cameraEye += (target - cameraEye) * min(1, ctx.dt * 3.0)
        s.camera(eye: cameraEye, center: SIMD3(p.x, p.y - 40, p.z - 120))
        s.perspective(fov: .pi / 3.1, near: 1, far: 9000)
    }

    /// キー + フィル + リムの 3 灯（1 本目の所見: PBR は IBL が無く直接光が `albedo/π` で
    /// 入るうえ `directionalLight` に強度引数が無いため、単灯だと必ず沈む）。
    private func setLights(_ ctx: SceneContext) {
        let s = ctx.sketch

        // `SALVAGE_KEY_LIGHT_ONLY=1`: キー 1 灯 + 低 ambient（Examples の Shadow と同条件）。
        // 影が見えない原因が「灯数と ambient で明るさを稼いでいるから」なのかを切り分ける。
        if PlayScene.keyLightOnly {
            s.ambientLight(45)
            s.directionalLight(-0.35, 0.82, -0.45, color: Color(r: 1.0, g: 0.96, b: 0.9))
            return
        }

        s.ambientLight(spec.ambient)
        s.directionalLight(-0.35, 0.82, -0.45, color: Color(r: 1.0, g: 0.96, b: 0.9))
        s.directionalLight(
            0.5, 0.25, 0.55,
            color: Color(
                r: spec.fogTint.x / 255 * 1.6,
                g: spec.fogTint.y / 255 * 1.6,
                b: spec.fogTint.z / 255 * 1.6))
        s.directionalLight(
            0.15, 0.05, -0.9,
            color: Color(r: 0.55, g: 0.42, b: 0.3))
    }

    private func drawFloor(_ ctx: SceneContext) {
        let s = ctx.sketch
        guard let floor = assets?.floor else { return }
        let tile: Float = 320
        let count = 6
        s.push()
        if !PlayScene.shadowDebug { s.texture(floor) }
        s.fill(255, 255, 255)
        s.metallic(0.1)
        s.roughness(0.85)
        for iz in -count...count {
            for ix in -count...count {
                let x = Float(ix) * tile
                let z = Float(iz) * tile
                if sqrt(x * x + z * z) > world.arenaRadius + tile { continue }
                s.push()
                s.translate(x, world.floorY, z)
                s.rotateX(.pi / 2)
                s.plane(tile, tile)
                s.pop()
            }
        }
        s.noTexture()
        s.pop()
    }

    private func drawObstacles(_ ctx: SceneContext) {
        let s = ctx.sketch
        s.fill(spec.obstacleColor.x, spec.obstacleColor.y, spec.obstacleColor.z)
        s.metallic(0.25)
        s.roughness(0.72)
        for o in world.obstacles {
            s.push()
            s.translate(o.pos.x, o.pos.y, o.pos.z)
            s.rotateY(o.spin)
            s.rotateZ(sin(o.phase) * 0.12)
            s.scale(spec.obstacleScale)
            if let mesh = assets?.obstacle, !PlayScene.usePrimitives {
                s.mesh(mesh)
            } else {
                s.box(1.1, 1.4, 1.1)
            }
            s.pop()
        }
    }

    private func drawCores(_ ctx: SceneContext) {
        let s = ctx.sketch
        s.fill(spec.coreColor.x, spec.coreColor.y, spec.coreColor.z)
        s.emissive(Color.rgb255(spec.coreColor * 0.35))
        s.metallic(0.15)
        s.roughness(0.28)
        for c in world.cores where c.alive {
            s.push()
            s.translate(c.pos.x, c.pos.y, c.pos.z)
            s.rotateY(c.spin)
            s.rotateX(c.spin * 0.6)
            s.scale(48)
            if let mesh = ctx.shared.core, !PlayScene.usePrimitives {
                s.mesh(mesh)
            } else {
                s.sphere(1.0, detail: 16)
            }
            s.pop()
        }
        s.emissive(0)
    }

    private func drawBeacon(_ ctx: SceneContext) {
        let s = ctx.sketch
        guard let beacon = ctx.shared.beacon, !PlayScene.usePrimitives else {
            s.push()
            s.translate(0, world.floorY - 150, 0)
            s.fill(230, 236, 240)
            s.cylinder(radius: 40, height: 300)
            s.pop()
            return
        }
        s.push()
        s.translate(0, world.floorY, 0)
        s.rotateY(elapsed * 0.4)
        s.scale(150)
        s.fill(230, 236, 240)
        s.emissive(Color.rgb255(SIMD3(60, 70, 76)))
        s.metallic(0.2)
        s.roughness(0.34)
        s.mesh(beacon)
        s.emissive(0)
        s.pop()
    }

    private func drawPlayer(_ ctx: SceneContext) {
        let s = ctx.sketch
        let p = world.player
        // 被弾直後は点滅させる（無敵時間が見えるように）
        if world.invulnerable > 0 && Int(elapsed * 12) % 2 == 0 { return }
        s.push()
        s.translate(p.pos.x, p.pos.y, p.pos.z)
        let heading = atan2(p.vel.x, p.vel.z)
        s.rotateY(heading)
        s.rotateX(min(0.35, simd_length(SIMD2(p.vel.x, p.vel.z)) / 1500))
        s.scale(62)
        s.fill(150, 232, 250)
        s.emissive(Color.rgb255(SIMD3(24 + flash * 110, 62 + flash * 20, 76 + flash * 20)))
        s.metallic(0.16)
        s.roughness(0.36)
        if let mesh = ctx.shared.drone, !PlayScene.usePrimitives {
            s.mesh(mesh)
        } else {
            s.box(1.6, 0.5, 2.2)
        }
        s.emissive(0)
        s.pop()

        // 機首の標識灯。上から見た皿だけだと向きも所在も分からないので足す
        s.push()
        s.translate(p.pos.x, p.pos.y - 26, p.pos.z)
        s.rotateY(heading)
        s.translate(0, 0, -46)
        s.fill(255, 246, 200)
        s.emissive(Color.rgb255(SIMD3(200, 170, 90)))
        s.sphere(11, detail: 12)
        s.emissive(0)
        s.pop()
    }
}

/// 結果表示。ここもステージ固有アセットを持たない。
@MainActor
final class ResultScene: Scene {
    let id = "result"
    private let success: Bool
    private let collected: Int
    private let reached: Int
    private var elapsed: Float = 0

    init(success: Bool, collected: Int, reached: Int) {
        self.success = success
        self.collected = collected
        self.reached = reached
    }

    var hudLines: [String] {
        [
            success ? "SALVAGE COMPLETE" : "SALVAGE LOST",
            "cores \(collected)   stages \(reached)/\(StageSpec.all.count)",
        ]
    }

    func enter(_ scope: SceneScope, _ ctx: SceneContext) {
        elapsed = 0
    }

    func update(_ ctx: SceneContext) -> SceneRequest? {
        elapsed += ctx.dt
        if ctx.demo && elapsed > 3.5 { return .title }
        if ctx.input.confirm && elapsed > 0.4 { return .title }
        return nil
    }

    func draw(_ ctx: SceneContext) {
        let s = ctx.sketch
        if success {
            s.background(8, 18, 16)
        } else {
            s.background(16, 8, 10)
        }

        s.camera(eye: SIMD3(0, -140, 520), center: SIMD3(0, -30, 0))
        s.perspective(fov: .pi / 3.2, near: 1, far: 5000)
        s.ambientLight(96)
        s.directionalLight(-0.3, 0.8, -0.4, color: Color(r: 1, g: 0.94, b: 0.86))
        s.directionalLight(0.6, 0.1, 0.5, color: Color(r: 0.3, g: 0.4, b: 0.55))
        s.pbr(true)
        s.noStroke()

        if let core = ctx.shared.core {
            for i in 0..<max(1, min(collected, 12)) {
                let a = Float(i) * 0.62 + elapsed * 0.35
                let r: Float = 90 + Float(i) * 16
                s.push()
                s.translate(cos(a) * r, -40 + sin(elapsed + Float(i)) * 14, sin(a) * r)
                s.rotateY(elapsed + Float(i))
                s.scale(30)
                if success {
                    s.fill(140, 236, 190)
                    s.emissive(Color.rgb255(SIMD3(40, 90, 70)))
                } else {
                    s.fill(200, 120, 120)
                    s.emissive(Color.rgb255(SIMD3(50, 20, 24)))
                }
                s.metallic(0.3)
                s.roughness(0.35)
                s.mesh(core)
                s.emissive(0)
                s.pop()
            }
        }
    }
}
