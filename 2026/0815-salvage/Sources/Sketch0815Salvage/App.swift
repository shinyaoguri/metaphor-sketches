import Foundation
import metaphor
import simd

/// **salvage** — 沈んだ構造物から動力コアを回収して脱出する 3 ステージのゲーム。
///
/// metaphor の「作品駆動検証」（[Epic #414](https://github.com/shinyaoguri/metaphor/issues/414)）の
/// **2 本目**。1 本目 `0815-strata` が残した 2 つの宿題に答えるために作っている:
///
/// 1. **シーンごとにアセットが入れ替わる型**にして
///    [#571](https://github.com/shinyaoguri/metaphor/issues/571)「Scene = 寿命境界」の要否を判定する
///    （1 本目はシーンがリソースを持たず判定できなかった）
/// 2. **AI 単独制作実験**（ロードマップ決定 7）— 人間の目視に頼らず Probe で自己検証しながら
///    作り、詰まりを全部 Issue へ返す
///
/// 構成:
/// - シーン: `title` → `hull` → `reactor` → `vent` → `result`
/// - ステージ固有アセット（モデル / 床テクスチャ / 環境音 / 背景動画）は
///   `PlayScene.enter` でロードし、`SceneScope` に預けて退出時に解放する
/// - 共有アセット（ドローン / コア / ビーコン / SE）は起動時に 1 度だけ読む
///
/// 操作:
/// - `W A S D` / 矢印キー: 移動、`space`: 開始・決定
/// - `1`〜`3`: ステージ直行（検証用）、`t`: タイトルへ、`h`: HUD、`g`: パラメータ GUI
///
/// 環境変数:
/// - `SALVAGE_DEMO=1` 自動操縦（ソーク用）、`SALVAGE_ASSET_CACHE=1` ライブラリのキャッシュを使う
/// - `SALVAGE_SYPHON` / `SALVAGE_FULLSCREEN` / `SALVAGE_WIDTH` / `SALVAGE_HEIGHT` / `SALVAGE_WORKDIR`
@main
final class Sketch0815Salvage: Sketch {
    // MARK: - Parameter Store

    @Param(min: 0, max: 1) var ambienceVolume: Float = 0.45
    @Param(min: 0, max: 1) var effectVolume: Float = 0.7
    @Param var showHUD: Bool = true
    @Param var showGUI: Bool = false

    // MARK: - 構成（起動時に決めて途中で変えない）

    private let demoMode = Env.bool("SALVAGE_DEMO")

    var config: SketchConfig {
        let syphonName = Env.syphonName()
        return SketchConfig(
            width: Env.int("SALVAGE_WIDTH", default: 1280, min: 320, max: 7680),
            height: Env.int("SALVAGE_HEIGHT", default: 720, min: 240, max: 4320),
            title: "0815-salvage",
            fps: 60,
            syphonName: syphonName,
            syphon: syphonName != nil,
            windowScale: 0.75,
            fullScreen: Env.bool("SALVAGE_FULLSCREEN")
        )
    }

    // MARK: - 状態

    private var ledger = AssetLedger()
    private var shared: SharedAssets!
    private var director: SceneDirector!
    private var confirmLatch = false
    private var pendingRequest: SceneRequest?
    private var startedAt: Float = 0
    private var worstFrameMs: Float = 0

    func setup() {
        // .app 起動では cwd が `/` になり、Probe（`.metaphor/probe/`）も
        // Parameter Store も書けない場所を向く（#688 / cli#133）。
        if let workdir = Env.string("SALVAGE_WORKDIR") {
            FileManager.default.changeCurrentDirectoryPath(workdir)
        }

        frameRate(60)
        textFont("Menlo")

        // 接地感（プレイヤーと障害物がどこに居るか）が影でしか出ないので入れる。
        if !Env.bool("SALVAGE_NO_SHADOWS") {
            enableShadows()
            shadowBias(Env.float("SALVAGE_SHADOW_BIAS", default: 0.002, min: 0.00001, max: 0.1))
        }
        // ポストは個別に落とせるようにしておく（1 本目の所見: 絵が壊れたとき
        // ライブラリ側とスケッチ側のどちらが原因か切り分けられなくなる）。
        if Env.string("SALVAGE_POSTFX")?.lowercased() != "none" {
            addPostEffect(BloomEffect(intensity: 0.34, threshold: 0.72))
        }

        shared = SharedAssets(sketch: self, ledger: ledger)
        startedAt = time

        let ctx = context(dt: 0)
        director = SceneDirector(initial: Sketch0815Salvage.startRequest(), ctx: ctx) {
            [unowned self] request in
            self.makeScene(request)
        }

        logStartup()
    }

    func draw() {
        let dt = min(deltaTime, 1.0 / 20)  // 大きなヒッチで物理が飛ばないよう上限を切る
        worstFrameMs = max(worstFrameMs, deltaTime * 1000)

        var ctx = context(dt: dt)
        if let request = pendingRequest {
            pendingRequest = nil
            director.go(to: request, ctx: ctx)
            ctx = context(dt: dt)
        }

        director.update(ctx)
        director.draw(ctx)
        confirmLatch = false

        recordProbe()

        if showHUD { drawHUD() }
        if showGUI {
            resetMatrix()
            gui.params()
        }
    }

    /// 検証用の開始シーン。`SALVAGE_START=title|hull|reactor|vent|result`。
    ///
    /// 各シーンの絵を Probe で確かめるのに、毎回タイトルから遊んで到達するのは現実的でない。
    /// **ライブラリ側に「任意の状態から起動する」手段が無い**ので作品側で口を開けた
    /// （AI が自分で絵を検証するには、こういう入口が要る、という所見でもある）。
    static func startRequest() -> SceneRequest {
        guard let name = Env.string("SALVAGE_START")?.lowercased() else { return .title }
        switch name {
        case "title": return .title
        case "result": return .result(success: true, collected: 21, reached: 3)
        default:
            if let index = StageSpec.all.firstIndex(where: { $0.id == name }) {
                return .stage(index)
            }
            return .title
        }
    }

    // MARK: - シーン生成

    private func makeScene(_ request: SceneRequest) -> any Scene {
        switch request {
        case .title:
            return TitleScene()
        case .stage(let index):
            let spec = StageSpec.all[min(index, StageSpec.all.count - 1)]
            // 直前がプレイ中のステージなら、ライフと回収数を引き継ぐ
            let previous = director?.current as? PlayScene
            let lives = previous.map { $0.livesLeft } ?? 3
            let collected = previous.map { $0.totalCollected } ?? 0
            return PlayScene(
                spec: spec, index: index,
                lives: index == 0 ? 3 : max(1, lives),
                collected: index == 0 ? 0 : collected)
        case .result(let success, let collected, let reached):
            return ResultScene(success: success, collected: collected, reached: reached)
        }
    }

    private func context(dt: Float) -> SceneContext {
        SceneContext(
            sketch: self,
            shared: shared,
            ledger: ledger,
            input: pollInput(),
            dt: dt,
            time: time,
            width: Float(width),
            height: Float(height),
            demo: demoMode
        )
    }

    // MARK: - 入力

    /// キーボードのポーリング。metaphor は `isKeyDown(keyCode)` を提供するので、
    /// 押しっぱなしの移動はイベントではなくここで拾う。
    private func pollInput() -> InputState {
        var input = InputState()
        var move = SIMD2<Float>.zero
        if isKeyDown(13) || isKeyDown(126) { move.y -= 1 }  // W / ↑ = 奥
        if isKeyDown(1) || isKeyDown(125) { move.y += 1 }  // S / ↓
        if isKeyDown(0) || isKeyDown(123) { move.x -= 1 }  // A / ←
        if isKeyDown(2) || isKeyDown(124) { move.x += 1 }  // D / →
        let length = simd_length(move)
        if length > 1 { move /= length }
        input.move = move
        input.confirm = confirmLatch
        return input
    }

    func keyPressed() {
        guard let code = keyCode else { return }
        switch code {
        case 49, 36:  // space / return
            confirmLatch = true
        case 18: pendingRequest = .stage(0)
        case 19: pendingRequest = .stage(1)
        case 20: pendingRequest = .stage(2)
        case 17: pendingRequest = .title  // t
        case 4: showHUD.toggle()  // h
        case 5: showGUI.toggle()  // g
        default: break
        }
    }

    // MARK: - HUD

    private func drawHUD() {
        resetMatrix()
        noStroke()

        // result は中央に大きく出すので、左上のパネルは重ねない
        let lines = director.current.id == "result" ? [] : director.current.hudLines
        if !lines.isEmpty {
            fill(0, 0, 0, 130)
            rect(20, 20, 420, Float(lines.count) * 22 + 20)
            fill(236, 240, 244)
            textSize(15)
            for (i, line) in lines.enumerated() {
                text(line, 34, 46 + Float(i) * 22)
            }
        }

        if director.current.id == "title" {
            fill(238, 244, 250)
            textSize(46)
            textAlign(.center)
            text("SALVAGE", Float(width) / 2, Float(height) * 0.68)
            textSize(15)
            fill(150, 178, 194)
            text(
                demoMode ? "demo mode — auto pilot" : "WASD / arrows to move   ·   space to dive",
                Float(width) / 2, Float(height) * 0.74)
            textAlign(.left)
        }

        if director.current.id == "result" {
            fill(238, 244, 250)
            textSize(34)
            textAlign(.center)
            for (i, line) in director.current.hudLines.enumerated() {
                text(line, Float(width) / 2, Float(height) * 0.66 + Float(i) * 40)
                textSize(18)
            }
            textAlign(.left)
        }

        // 右下に寿命の台帳（この作品の主題そのものなので常時出す）
        fill(0, 0, 0, 110)
        rect(Float(width) - 300, Float(height) - 92, 280, 72)
        fill(190, 206, 216)
        textSize(12)
        text("assets live \(ledger.live)  loads \(ledger.loads)  frees \(ledger.unloads)", Float(width) - 288, Float(height) - 68)
        text(String(format: "last load %.1f ms   cycles %d", ledger.lastLoadMillis, director.cycles), Float(width) - 288, Float(height) - 50)
        text(
            "cache \(StageAssets.useLibraryCache ? "library" : "off")   scene \(director.current.id)",
            Float(width) - 288, Float(height) - 32)
    }

    // MARK: - Probe（AI が外から状態を読むための出口）

    private func recordProbe() {
        probe("scene", director.current.id)
        probe("sceneTransitions", director.transitions)
        probe("cycles", director.cycles)
        probe("demo", demoMode)
        probe("assetsLive", ledger.live)
        probe("assetsLoads", ledger.loads)
        probe("assetsFrees", ledger.unloads)
        probe("assetLoadMs", ledger.lastLoadMillis)
        probe("assetLoadMsTotal", ledger.totalLoadMillis)
        probe("assetFailures", ledger.failures.joined(separator: ","))
        probe("assetCacheMode", StageAssets.useLibraryCache ? "library" : "off")
        probe("uptimeSec", Double(time - startedAt))
        probe("worstFrameMs", Double(worstFrameMs))

        if let play = director.current as? PlayScene {
            probe("stage", play.spec.id)
            probe("collectedTotal", play.totalCollected)
            probe("lives", play.livesLeft)
        }
    }

    private func logStartup() {
        let mode = demoMode ? "demo" : "manual"
        let cache = StageAssets.useLibraryCache ? "library cache" : "no cache"
        print("[salvage] start — \(mode), \(cache), shared assets live=\(ledger.live)")
        if !ledger.failures.isEmpty {
            print("[salvage] asset failures: \(ledger.failures.joined(separator: ", "))")
        }
    }
}
