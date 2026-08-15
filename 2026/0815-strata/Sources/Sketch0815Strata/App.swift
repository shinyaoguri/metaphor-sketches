import Foundation
import metaphor
import simd

/// **strata** — 地層が隆起し、削られ、露出し、沈静するのを繰り返す生成的地形。
///
/// metaphor の「作品駆動検証」（[Epic #414](https://github.com/shinyaoguri/metaphor/issues/414)）の
/// リファレンス作品。29 行のスケッチではなく「複数シーン + 複数入力 + 無人稼働」を
/// satisfies する 1 本を作り切り、そこで踏んだ穴をライブラリへ Issue として返す。
///
/// - 4 シーン（formation → erosion → strata → dormant）を自律タイマーで巡回し、
///   OSC からも切り替えられる
/// - 入力 2 系統: カメラ（動き量・色温度）と OSC（シーン/パラメータ）
/// - 単体アプリ常設と Syphon 送出の両対応（環境変数で切替）
///
/// 操作:
/// - `space` 次のシーン / `1`〜`4` シーン直接指定 / `r` 地形の再生成
/// - `h` HUD 表示 / `g` パラメータ GUI
///
/// 環境変数:
/// - `STRATA_SYPHON=1`（または名前）で Syphon 出力、`STRATA_FULLSCREEN=1` で全画面
/// - `STRATA_GRID`（既定 128）/ `STRATA_HOLD`（秒・既定 90）/ `STRATA_OSC_PORT`（既定 9000）
@main
final class Sketch0815Strata: Sketch {
    // MARK: - Parameter Store（外部からも GUI からも同じ値を触る）

    @Param(min: 0.2, max: 2.0) var elevationScale: Float = 1.0
    @Param(min: 0.0, max: 2.0) var cameraDrive: Float = 1.0
    @Param(min: 0.0, max: 3.0) var orbitScale: Float = 1.0
    @Param(min: 0.0, max: 1.5) var bandContrastScale: Float = 1.0
    @Param(min: 5, max: 600) var holdSeconds: Float = 90
    @Param var autoAdvance: Bool = true
    @Param var showHUD: Bool = true
    @Param var showGUI: Bool = false

    // MARK: - 構成（環境変数で決まる。起動後は変えない）

    private let gridSize = Env.int("STRATA_GRID", default: 128, min: 16, max: 512)
    private let oscPort = UInt16(Env.int("STRATA_OSC_PORT", default: 9000, min: 1, max: 65535))
    private let terrainExtent: Float = 1400

    var config: SketchConfig {
        let syphonName = Env.syphonName()
        return SketchConfig(
            width: Env.int("STRATA_WIDTH", default: 1920, min: 320, max: 7680),
            height: Env.int("STRATA_HEIGHT", default: 1080, min: 240, max: 4320),
            title: "0815-strata",
            fps: 60,
            syphonName: syphonName,
            syphon: syphonName != nil,
            windowScale: 0.5,
            fullScreen: Env.bool("STRATA_FULLSCREEN")
        )
    }

    // MARK: - 状態

    private var terrain: Terrain!
    private var director: SceneDirector!
    private var sense: CameraSense!
    private var osc: OSCControl!
    private var orbitAngle: Float = 0
    private var terrainSeed: UInt64 = 20_260_815

    private let bloom = BloomEffect(intensity: 0.35, threshold: 0.8)
    private let vignette = VignetteEffect(intensity: 0.4, smoothness: 0.5)
    private let grade = ColorGradeEffect()

    /// 有効にするポストエフェクト。既定は 3 つとも。
    /// `STRATA_POSTFX=none` で全部落とし、`bloom,grade` のように列挙もできる
    /// （どのエフェクトが絵を壊しているかを切り分けるための入口）。
    private let enabledPostEffects: [String] = {
        guard let spec = Env.string("STRATA_POSTFX") else {
            return ["bloom", "vignette", "grade"]
        }
        if spec.lowercased() == "none" { return [] }
        return spec.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
    }()

    // 無人稼働の自己申告用。Probe から読めるようにしておく。
    private var startedAt: Float = 0
    private var worstFrameMs: Float = 0

    func setup() {
        // .app から起動すると cwd が `/` になり、Probe（`.metaphor/probe/`）も
        // Parameter Store（`.metaphor/params/`）も書けない場所を向く。
        // どちらも cwd 相対の契約なので、常設運用では置き場を指定できる必要がある。
        if let workdir = Env.string("STRATA_WORKDIR") {
            if FileManager.default.changeCurrentDirectoryPath(workdir) {
                print("[strata] workdir=\(workdir)")
            } else {
                print("[strata] workdir not usable: \(workdir)")
            }
        }

        frameRate(60)

        let mesh = createDynamicMesh()
        terrain = Terrain(
            mesh: mesh, gridSize: gridSize, extent: terrainExtent, seed: terrainSeed
        )

        director = SceneDirector(
            entries: Scenes.all,
            holdSeconds: Env.float("STRATA_HOLD", default: 90, min: 5, max: 3600),
            transitionSeconds: Env.float("STRATA_TRANSITION", default: 6, min: 0.1, max: 60)
        )
        // `@Param` は params.json から復元済みで setup() は復元値を見る。
        // 環境変数が**明示された時だけ**それを優先し、そうでなければ
        // 前回 GUI / OSC で決めた値を残す（毎回 90 に戻ると常設で困る）。
        if Env.string("STRATA_HOLD") != nil {
            holdSeconds = director.holdSeconds
        }

        // カメラは「センサ」として使うので低解像度で十分。
        // 権限が無い / デバイスが無い場合も作品は自律的に動き続ける。
        let capture = Env.bool("STRATA_NO_CAMERA")
            ? nil
            : createCapture(width: 320, height: 180)
        sense = CameraSense(capture: capture)
        sense.requestAccessIfNeeded()

        osc = OSCControl(port: oscPort)

        // ポストは HUD を含む画面全体に一律で掛かる（UI だけ外す手段が無い）。
        // 何がどう効いているかを切り分けられるよう、個別に選べるようにしておく。
        // `STRATA_POSTFX=none` で全部落とす / `bloom,grade` のように列挙も可。
        for name in enabledPostEffects {
            switch name {
            case "bloom": addPostEffect(bloom)
            case "vignette": addPostEffect(vignette)
            case "grade": addPostEffect(grade)
            default: break
            }
        }

        startedAt = time
        logStartup()
    }

    func draw() {
        applyOSC(osc.poll())

        director.holdSeconds = autoAdvance ? holdSeconds : .greatestFiniteMagnitude
        director.update(dt: deltaTime)
        sense.update(frameCount: frameCount, decay: 0.965)

        var profile = director.profile
        profile.elevation *= elevationScale
        profile.energyResponse *= cameraDrive
        profile.bandContrast *= bandContrastScale
        profile.cameraOrbitSpeed *= orbitScale

        terrain.update(profile: profile, drive: sense.drive, t: time)

        background(
            profile.background.x * 255, profile.background.y * 255, profile.background.z * 255
        )

        setCamera(profile)
        setLights(profile)
        applyPostEffects(profile)

        pbr(true)
        metallic(profile.metallic)
        roughness(profile.roughness)
        terrain.draw(in: self)

        recordProbe(profile)

        if showHUD { drawHUD(profile) }
        if showGUI {
            resetMatrix()
            gui.params()
        }
    }

    // MARK: - 描画の各段

    private func setCamera(_ profile: SceneProfile) {
        orbitAngle += deltaTime * profile.cameraOrbitSpeed
        let eye = SIMD3<Float>(
            cos(orbitAngle) * profile.cameraRadius,
            -profile.cameraHeight,
            sin(orbitAngle) * profile.cameraRadius
        )
        // 高さは -Y 方向。up は metaphor（Processing 由来）の既定に合わせて +Y。
        camera(eye: eye, center: SIMD3<Float>(0, -profile.cameraLookHeight, 0))
        perspective(fov: profile.fov, near: 1, far: 8000)
    }

    /// キー + フィル + リムの 3 灯。
    ///
    /// metaphor の PBR は直接光が `albedo / π` で入り IBL も無い。加えて
    /// `directionalLight` に強度引数が無く固定 1.0 なので、キー 1 灯だと
    /// どれだけ ambient を上げても平坦に暗い絵にしかならない。灯数で稼ぐ。
    private func setLights(_ profile: SceneProfile) {
        ambientLight(profile.ambient)

        let key = profile.lightDirection
        directionalLight(key.x, key.y, key.z, color: Color(r: 1.0, g: 0.96, b: 0.9))

        let fill = profile.fill
        directionalLight(
            -key.x, 0.55, -key.z,
            color: Color(r: fill * 0.5, g: fill * 0.6, b: fill * 0.8)
        )

        let rim = profile.rim
        directionalLight(
            -key.z, 0.14, key.x,
            color: Color(r: rim * 0.95, g: rim * 0.62, b: rim * 0.34)
        )
    }

    private func applyPostEffects(_ profile: SceneProfile) {
        bloom.intensity = profile.bloom
        bloom.threshold = profile.bloomThreshold

        // VignetteEffect の `intensity` は「強度」ではなく **黒に落ちきる半径**で、
        // シェーダは smoothstep(intensity, intensity - smoothness, dist)。
        // dist は中心 0 〜 隅 0.707 なので、既定の intensity 0.5 では画面の
        // 大半が真っ黒になる（値が大きいほど弱い、という逆向きの意味）。
        // profile 側は素直な 0..1 の強度で持ち、ここで半径へ写す。
        vignette.smoothness = 0.5
        vignette.intensity = 1.2 - profile.vignette * 0.55

        grade.brightness = profile.brightness
        grade.contrast = profile.contrast
        grade.saturation = profile.saturation
        grade.temperature = profile.temperature
    }

    // MARK: - 入力

    private func applyOSC(_ commands: OSCControl.Commands) {
        if let index = commands.sceneIndex { director.go(to: index) }
        if let name = commands.sceneName, let index = director.index(ofName: name) {
            director.go(to: index)
        }
        if commands.advance { director.advance() }
        if let seed = commands.regenerateSeed { regenerate(seed: seed) }

        for write in commands.paramWrites {
            // Parameter Store は外部クライアント（GUI / AI / ここ）に対して対称。
            // 宣言レンジへのクランプはストア側が行う。
            _ = params.setValue(.float(Double(write.value)), for: write.name)
        }
    }

    func keyPressed() {
        switch key {
        case " ": director.advance()
        case "1": director.go(to: 0)
        case "2": director.go(to: 1)
        case "3": director.go(to: 2)
        case "4": director.go(to: 3)
        case "r": regenerate(seed: terrainSeed &+ 1)
        case "h": showHUD.toggle()
        case "g": showGUI.toggle()
        default: break
        }
    }

    private func regenerate(seed: UInt64) {
        terrainSeed = seed
        terrain.generate(seed: seed)
    }

    // MARK: - 観測

    private func recordProbe(_ profile: SceneProfile) {
        let frameMs = deltaTime * 1000
        if frameMs > worstFrameMs && frameCount > 120 { worstFrameMs = frameMs }

        probe("scene", director.currentName)
        probe("sceneIndex", director.currentIndex)
        probe("sceneSwitches", director.switchCount)
        probe("transition", Double(director.transition))
        probe("uptimeSec", Double(time - startedAt))
        probe("worstFrameMs", Double(worstFrameMs))
        probe("cameraAvailable", sense.drive.available)
        probe("cameraAuthorization", sense.authorizationLabel)
        probe("cameraSamples", sense.sampleCount)
        probe("cameraDropouts", sense.dropoutCount)
        probe("senseEnergy", Double(sense.drive.energy))
        probe("senseLuminance", Double(sense.drive.luminance))
        probe("oscRunning", osc.isRunning)
        probe("oscMessages", osc.messageCount)
        probe("vertices", terrain.vertexCount)
        probe("triangles", terrain.triangleCount)
        probe("elevation", Double(profile.elevation))
    }

    private func drawHUD(_ profile: SceneProfile) {
        resetMatrix()
        noStroke()
        fill(0, 0, 0, 120)
        rect(20, 20, 340, 132)

        fill(235, 235, 240)
        textSize(13)
        let remaining = max(0, director.holdSeconds - director.elapsedInScene)
        let holdText = autoAdvance ? String(format: "%.0fs", remaining) : "held"
        text("scene  \(director.currentName)  (\(holdText))", 34, 46)
        text(
            director.isTransitioning
                ? String(format: "transition  %.0f%%", director.transition * 100)
                : "transition  -",
            34, 66
        )
        text(
            sense.drive.available
                ? String(
                    format: "camera  %@ (%@)  e=%.2f l=%.2f",
                    sense.deviceLabel, sense.authorizationLabel,
                    sense.drive.energy, sense.drive.luminance
                )
                : "camera  unavailable",
            34, 86
        )
        text(
            osc.isRunning
                ? "osc  :\(osc.port)  msgs=\(osc.messageCount)  \(osc.lastAddress)"
                : "osc  down",
            34, 106
        )
        text(
            String(
                format: "mesh  %d verts  uptime %.0fs", terrain.vertexCount, time - startedAt
            ),
            34, 126
        )
    }

    private func logStartup() {
        print("[strata] grid=\(gridSize) verts=\(terrain.vertexCount) tris=\(terrain.triangleCount)")
        print("[strata] camera=\(sense.deviceLabel) auth=\(sense.authorizationLabel)")
        if osc.isRunning {
            print("[strata] osc listening on :\(osc.port)")
        } else {
            print("[strata] osc unavailable: \(osc.startupError ?? "unknown")")
        }
        if let name = Env.syphonName() {
            print("[strata] syphon publishing as \"\(name)\"")
        }
    }
}

// MARK: - 環境変数

/// 常設運用は「起動時の環境変数で決まる」ものが多いので、読み取りを 1 か所に集める。
enum Env {
    static func string(_ name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func bool(_ name: String) -> Bool {
        guard let value = string(name)?.lowercased() else { return false }
        return value != "0" && value != "false" && value != "no"
    }

    static func int(_ name: String, default fallback: Int, min lo: Int, max hi: Int) -> Int {
        guard let value = string(name).flatMap(Int.init) else { return fallback }
        return Swift.min(Swift.max(value, lo), hi)
    }

    static func float(_ name: String, default fallback: Float, min lo: Float, max hi: Float)
        -> Float
    {
        guard let value = string(name).flatMap(Float.init) else { return fallback }
        return Swift.min(Swift.max(value, lo), hi)
    }

    /// Syphon 名。`STRATA_SYPHON=1` なら既定名、文字列ならその名前。
    /// `metaphor run --syphon` 経由（`METAPHOR_SYPHON_NAME`）も尊重する。
    static func syphonName() -> String? {
        if let injected = string("METAPHOR_SYPHON_NAME") { return injected }
        guard let value = string("STRATA_SYPHON") else { return nil }
        let lowered = value.lowercased()
        if lowered == "0" || lowered == "false" || lowered == "no" { return nil }
        if lowered == "1" || lowered == "true" || lowered == "yes" { return "0815-strata" }
        return value
    }
}
