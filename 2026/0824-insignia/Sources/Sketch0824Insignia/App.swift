import Foundation
import metaphor
import simd

// 0824-insignia — metaphor のロゴを、四方から検分できる立体の記章にする。
//
// 1 本の連続したリボンが巻きながら細り、両端が一点に収束する貝殻／ドリル状のらせん。
// 真横（プリセット "m"）から見ると、脚が基線に着いた小文字の `m` に読める。
//
// 形の数式は Geometry.swift（metaphor に依存しない純粋な層）。
// 正しく組めているかの機械判定は Instrument.swift。検証の一次記録は frame.json の `custom` と
// 本リポジトリの検証 issue #27。

@main
final class Sketch0824Insignia: Sketch {
    var config: SketchConfig {
        SketchConfig(width: 1280, height: 800, title: "0824-insignia")
    }

    // MARK: - 見た目の定数（仕様 §3〜§5）

    /// 背景の濃紺。
    private let backdrop = Color(hex: 0x0a_1225)
    /// 乳白／クリーム。ハイライトを出さないマットな殻の色。
    private let shell = Color(hex: 0xfa_f3ea)
    /// 半球光の「空」側。
    private let skyTint = Color(hex: 0xc8_d8f0)
    /// 半球光の「地面」側。
    private let groundTint = Color(hex: 0x5a_5348)

    private let fov: Float = 32 * .pi / 180
    private let shadowResolution = 4096

    // MARK: - ワールドスケール

    /// 仕様の論理単位（R0 = 1.0、LX = 3.05）に掛ける倍率。
    ///
    /// metaphor の影は焼き付け範囲を作品側から指定できない（`ShadowMap` の `sceneRadius` が
    /// 既定 500 のまま呼ばれる）ので、**作品の大きさのほうを影の範囲に合わせにいく**。
    /// `INSIGNIA_SCALE=1` にすれば仕様どおりの単位系で走り、影がどう壊れるかを対照実験できる。
    private let worldScale = Sketch0824Insignia.floatFromEnvironment("INSIGNIA_SCALE") ?? 120

    // MARK: - 状態

    private var tube: DynamicMesh?
    private var meshBounds: (min: SIMD3<Float>, max: SIMD3<Float>) = (.zero, .zero)
    private var boundingRadius: Float = 0

    private var viewIndex = 0
    private var transitionFrom: CameraPose?
    private var transitionStart: Float = 0
    private let transitionSeconds: Float = 0.55

    private var autoRotate = ProcessInfo.processInfo.environment["INSIGNIA_SPIN"] == "1"
    private var showFloor = ProcessInfo.processInfo.environment["INSIGNIA_FLOOR"] == "1"
    /// 影は既定で切る。
    ///
    /// 仕様 §4 はメッシュを castShadow だけにし、receiveShadow を切ることを求めている
    /// （コイル同士が影を落とし合うと、真横の `m` のシルエットが濁るため・仕様 §7-5）。
    /// metaphor には receiveShadow 相当の口が無く、`enableShadows()` は自己遮蔽まで込みで効くので、
    /// **受け手を置かない = 影そのものを切る**のが、仕様の意図にいちばん近い実現になる。
    /// 床（`f`）を出すと影も一緒に点く。`x` で明示的に切り替えられる（対照実験用）。
    private var shadowsOn = ProcessInfo.processInfo.environment["INSIGNIA_SHADOWS"] == "1"
    private var transparentSave = ProcessInfo.processInfo.environment["INSIGNIA_TRANSPARENT"] == "1"
    private var showHelp = true

    private var verdicts: [Verdict] = []
    private var savedShots: Set<String> = []
    /// 自動回転の 1 フレームあたりの角度。記録中だけ速める（1 周を短い連番に収めるため）。
    private var spinPerFrame: Float = 0.0045
    private var pendingSavePath: String?
    private var lastShotFrame: Int?
    private var recording = false
    private var recordingDone = false
    private var recordingEndFrame: Int?

    // MARK: - プリセット視点（仕様 §5）

    /// 注視点からカメラへ向かう方向。仕様は +y が上の流儀で書かれているので、
    /// `Insignia.yAxis` を掛けて metaphor のワールド（+y が下）へ移す。
    private struct PresetView {
        let key: String
        let label: String
        let direction: SIMD3<Float>
    }

    private let views: [PresetView] = [
        PresetView(key: "1", label: "m", direction: SIMD3(0, 0.08, 1)),
        PresetView(key: "2", label: "iso", direction: SIMD3(0.85, 0.55, 1)),
        PresetView(key: "3", label: "top", direction: SIMD3(0.001, 1, 0.02)),
        PresetView(key: "4", label: "axis", direction: SIMD3(1, 0.12, 0.08)),
    ]

    private struct CameraPose {
        var azimuth: Float
        var elevation: Float
        var distance: Float
    }

    // MARK: - setup

    func setup() {
        frameRate(60)

        // 1. 形が仕様どおりに組めているかを、描画を起こす前に機械判定する
        verdicts = Instrument.runAll(worldScale: worldScale, shadowResolution: shadowResolution)
        report(verdicts)

        // 2. メッシュを 1 度だけ組む（ワールド単位で焼き込む）
        let data = Insignia.build(scale: worldScale)
        meshBounds = Insignia.bounds(data)
        let mesh = createDynamicMesh()
        for vertex in data.vertices {
            // 法線と UV は「次に追加される頂点」に適用されるので、addVertex より先に置く
            mesh.addNormal(vertex.normal)
            mesh.addTexCoord(vertex.uv)
            mesh.addVertex(vertex.position)
        }
        var i = 0
        while i < data.indices.count {
            mesh.addTriangle(data.indices[i], data.indices[i + 1], data.indices[i + 2])
            i += 3
        }
        tube = mesh

        // 3. カメラ。近クリップを浅く取ると重なるコイルの前後がちらつくので、
        //    fov を望遠寄りにして near / far を作品の実寸に噛み合わせる（仕様 §7-2）
        boundingRadius = Insignia.boundingRadius(data)

        orbitCamera.target = center()
        orbitCamera.minDistance = 3.4 * worldScale
        orbitCamera.maxDistance = 26 * worldScale
        orbitCamera.damping = 0.86
        // damping は**生の差分を速度に足すだけで利得を補正しない**。
        // 定常状態の速度は 1/(1 - damping) 倍になるので、0.86 のままだと
        // ドラッグ量の 7.1 倍回ってしまう。感度側で割って 1:1 に戻す
        // （慣性の余韻は残したまま、総回転量が damping 無しと一致する）。
        //
        // `INSIGNIA_RAWCAM=1` はこの補正と下の押下ガードをまとめて外し、
        // **metaphor の素の挙動**を測れるようにする（metaphor#1099 / #1100 の再検証用。
        // tools/replay-input.py --raw が立てる）。作品の既定は補正ありのまま。
        orbitCamera.sensitivity = rawCam ? 0.005 : 0.005 * (1 - orbitCamera.damping)
        orbitCamera.zoomSensitivity = 0.6

        let initial = pose(for: views[0])
        orbitCamera.reset(
            distance: initial.distance, azimuth: initial.azimuth, elevation: initial.elevation)

        if showFloor { shadowsOn = true }
        if shadowsOn {
            enableShadows(resolution: shadowResolution)
            shadowBias(0.0006)
        }
    }

    // MARK: - draw

    func draw() {
        // 保存が予約されているフレームだけ、背景の α を落として描く。
        // `background()` は draw の**冒頭**でしか使えない（末尾で呼ぶと、その場で絵を消してから
        // 保存することになる。実際にそれで全面 α=0 の空 PNG を 1 度書き出した）。
        if pendingSavePath != nil, transparentSave {
            background(backdrop.r * 255, backdrop.g * 255, backdrop.b * 255, 0)
        } else {
            background(backdrop)
        }

        applyCamera()
        applyLights()

        noStroke()
        fill(shell)
        metallic(0)
        roughness(0.98)  // 完全マット。ハイライトを出さない
        if let tube {
            dynamicMesh(tube)
        }

        if showFloor {
            drawFloor()
        }

        drawOverlay()
        emitProbes()

        if inputLogEnabled, frameCount % 30 == 0 {
            logInput("tick")
        }

        captureIfRequested()
        flushPendingSave()
    }

    // MARK: - カメラ

    private func applyCamera() {
        // 投影は**毎フレーム**指定する。Canvas3D はフレーム開始で fov / near / far を
        // Processing 風の既定（fov 60°、カメラは画面ピクセル空間）へ戻すので、
        // setup() で 1 度呼んだだけでは効かない（絵が 2 倍遠くに見えて気付いた）。
        perspective(fov: fov, near: 0.08 * worldScale, far: 60 * worldScale)

        if autoRotate {
            orbitCamera.azimuth += spinPerFrame
        }

        // プリセットへの遷移中は補間で寄せる。ドラッグが入ったらその場で打ち切って手に返す。
        if let from = transitionFrom {
            if isMousePressed {
                transitionFrom = nil
            } else {
                let k = min(1, (time - transitionStart) / transitionSeconds)
                let e = k * k * (3 - 2 * k)  // smoothstep
                let to = pose(for: views[viewIndex])
                // 方位角は最短の向きに回す。自動回転で何周も進んだ後に
                // 素直に補間すると、目標へ着くまで逆向きに巻き戻ってしまう。
                orbitCamera.azimuth = from.azimuth + shortestArc(from.azimuth, to.azimuth) * e
                orbitCamera.elevation = lerp(from.elevation, to.elevation, e)
                orbitCamera.distance = lerp(from.distance, to.distance, e)
                if k >= 1 { transitionFrom = nil }
            }
        }

        orbitCamera.target = center()

        let held = (azimuth: orbitCamera.azimuth, elevation: orbitCamera.elevation)
        orbitControl()  // ドラッグで軌道回転、ホイールでズーム

        // `orbitControl()` は「押下中か」と「前フレームからの移動量」だけで回すので、
        // 押下状態や座標が飛ぶと、こちらの意図と無関係に回る。3 段で受け止める。
        let pressedNow = pressArrived && !rawCam
        pressArrived = false
        if (buttonStateSuspect && !rawCam) || pressedNow {
            // (1) 押されていないのに押下中とされているフレーム、(2) 押下が届いたフレーム。
            //     後者は「押した瞬間」であってドラッグではない（カーソルが前回位置から
            //     離れていると、その差がまるごと回転として入ってしまう）。
            //     どちらも回転だけ戻し、慣性も捨てる。ズームは戻さないのでホイールは効く。
            orbitCamera.reset(
                distance: orbitCamera.distance, azimuth: held.azimuth, elevation: held.elevation)
        } else {
            // (3) 念のための上限。1 フレームで 0.25rad（約 14°）を超える回転は
            //     入力の飛びとみなして頭を押さえる。素直なドラッグでは届かない値。
            // 1 フレームのあいだに角度が 2π を跨ぐことは無いので、生の差で見る
            // （shortestArc で畳むと、-3.2rad の飛びが +0.25rad の回転に化ける）。
            let maxStep: Float = rawCam ? .infinity : 0.25
            let dAz = orbitCamera.azimuth - held.azimuth
            if abs(dAz) > maxStep {
                orbitCamera.azimuth = held.azimuth + (dAz < 0 ? -maxStep : maxStep)
            }
            let dEl = orbitCamera.elevation - held.elevation
            if abs(dEl) > maxStep {
                orbitCamera.elevation = held.elevation + (dEl < 0 ? -maxStep : maxStep)
            }
        }
        camera(eye: orbitCamera.eye, center: orbitCamera.target, up: orbitCamera.up)
    }

    // MARK: - マウスの取りこぼし対策

    /// metaphor 側の「ボタン押下中」が現実とずれている疑いがあるか。
    ///
    /// ライブビューア（`metaphor watch`）は窓宛の NSEvent をローカルモニタで捕まえて
    /// 子スケッチへ転送するが、**窓枠やタイトルバーを掴んだ押下も転送される**一方で、
    /// リサイズ／移動のあいだ AppKit が回す内部トラッキングループはモニタを素通りするため、
    /// 対応する mouseUp が届かない。結果 `isMousePressed` が立ちっぱなしになり、
    /// **ボタンを押していないマウス移動だけでカメラが回り続ける**。
    ///
    /// スケッチ側から metaphor の押下状態は消せないので、矛盾を見つけて回転だけ打ち消す。
    /// 「押していない移動」として `mouseMoved()` が来たのに `isMousePressed` が真、が矛盾の印。
    private var buttonStateSuspect = false

    /// 押下がこのフレームに届いたか（押した瞬間をドラッグとして扱わないための印）。
    private var pressArrived = false

    /// 作品側の受け止め（感度補正・押下ガード・1 フレームの回転上限）を全部外すか。
    ///
    /// 外すと `orbitControl()` が回した量がそのまま方位角に出るので、上流が直ったかを
    /// **作品を書き換えずに**測れる。既定は false（作品としてはガードありが正しい姿）。
    private let rawCam = ProcessInfo.processInfo.environment["INSIGNIA_RAWCAM"] == "1"

    func mousePressed() {
        buttonStateSuspect = false  // 本物の押下が来た = 状態は信用できる
        pressArrived = true
        logInput("mousePressed")
    }

    func mouseReleased() {
        buttonStateSuspect = false
        logInput("mouseReleased")
    }

    func mouseDragged() {
        buttonStateSuspect = false
        logInput("mouseDragged")
    }

    func mouseMoved() {
        if isMousePressed, !buttonStateSuspect {
            buttonStateSuspect = true
            print("[input] 押していない移動が来たのに isMousePressed が真。回転を打ち消す")
            fflush(stdout)
        }
        logInput("mouseMoved")
    }

    /// `INSIGNIA_INPUTLOG=1` のとき、マウスイベントの到着を素で流す。
    /// 「どのイベントが落ちているか」を数えるための口。
    private func logInput(_ name: String) {
        guard inputLogEnabled else { return }
        print(
            "[input] \(name) frame=\(frameCount) isMousePressed=\(isMousePressed) "
                + "suspect=\(buttonStateSuspect) azimuth=\(String(format: "%.4f", orbitCamera.azimuth))")
        fflush(stdout)
    }

    private let inputLogEnabled = ProcessInfo.processInfo.environment["INSIGNIA_INPUTLOG"] == "1"

    /// プリセットの方向ベクトルから、オービットカメラの角度へ。
    private func pose(for view: PresetView) -> CameraPose {
        let d = normalize(
            SIMD3(view.direction.x, Insignia.yAxis * view.direction.y, view.direction.z))
        // 真上・真下は lookAt が退化する（up と視線が平行になる）ので、わずかに倒しておく
        let limit = Float.pi / 2 - 0.02
        let elevation = max(-limit, min(limit, asin(d.y)))
        return CameraPose(
            azimuth: atan2(d.x, d.z),
            elevation: elevation,
            distance: framedDistance(lookingFrom: d) * 1.28
        )
    }

    /// その視点から見たときに作品が画面に収まる距離。
    ///
    /// 外接球で一律に決めると、平たく見える視点（真横の `m` など）で画面がすかすかになる。
    /// バウンディングボックスの 8 隅をカメラ基底へ射影して、**その視点での実際の広がり**から出す。
    private func framedDistance(lookingFrom direction: SIMD3<Float>) -> Float {
        let forward = -direction
        var up = SIMD3<Float>(0, 1, 0)
        if abs(dot(forward, up)) > 0.99 { up = SIMD3(0, 0, 1) }
        let right = normalize(cross(forward, up))
        let camUp = normalize(cross(right, forward))

        let halfFovY = fov * 0.5
        let halfFovX = atan(tan(halfFovY) * (width / height))
        let c = center()

        // 隅ごとに「その点が視錐台に入る最小距離」を出して、その最大を採る。
        // 奥行きを一律に足すと、斜めから見たとき（iso）に必要以上へ引きすぎる。
        var needed: Float = 0
        for sx in [meshBounds.min.x, meshBounds.max.x] {
            for sy in [meshBounds.min.y, meshBounds.max.y] {
                for sz in [meshBounds.min.z, meshBounds.max.z] {
                    let v = SIMD3(sx, sy, sz) - c
                    let depth = dot(v, forward)
                    let spread = max(
                        abs(dot(v, right)) / tan(halfFovX),
                        abs(dot(v, camUp)) / tan(halfFovY))
                    needed = max(needed, depth + spread)
                }
            }
        }
        return needed
    }

    private func center() -> SIMD3<Float> {
        (meshBounds.min + meshBounds.max) * 0.5
    }

    // MARK: - ライト

    private func applyLights() {
        // ambientLight は fill と同じ colorMode のレンジ（既定 0〜255）、
        // directionalLight の color は Color（0…1 正規化）。同じ画面で両方のスケールを跨ぐので注意。
        ambientLight(skyTint.r * 255 * 0.34, skyTint.g * 255 * 0.34, skyTint.b * 255 * 0.34)

        // キーライト（影を落とす側）。方向は「光が進む向き」。
        // 画面の上は -y なので、上から差す光は +y へ進む。
        directionalLight(0.42, 1, -0.68, color: Color(r: 1, g: 0.98, b: 0.95), intensity: 2.8)

        // 半球光の地面側の代用。影を落とさない弱い返し光で、下面が黒く沈まないようにする。
        directionalLight(-0.25, -1, 0.35, color: groundTint, intensity: 0.55)
    }

    // MARK: - 床

    /// 影のキャッチャー。既定では出さない。
    ///
    /// コイル同士が影を落とし合うとシルエットが濁る（仕様 §7-5）。metaphor には
    /// `receiveShadow` 相当の口が無いので、**受け手を置かないこと**で同じ意図を満たしている。
    private func drawFloor() {
        push()
        fill(28, 34, 54)
        roughness(0.95)
        metallic(0)
        translate(center().x, meshBounds.max.y + 0.02 * worldScale, center().z)
        box(14 * worldScale, 0.01 * worldScale, 14 * worldScale)
        pop()
    }

    // MARK: - オーバーレイ

    private func drawOverlay() {
        guard showHelp else { return }

        let failed = verdicts.filter { !$0.passed }
        push()
        textSize(13)
        fill(226, 232, 245, 200)
        text("view \(views[viewIndex].label)   1 m / 2 iso / 3 top / 4 axis", 24, height - 74)
        text(
            "drag rotate · wheel zoom · a auto-rotate · f floor · x shadows · s save png · b alpha(効かない) · h ui",
            24, height - 52)
        fill(failed.isEmpty ? Color(r: 0.55, g: 0.85, b: 0.62) : Color(r: 0.95, g: 0.42, b: 0.42))
        text(
            failed.isEmpty
                ? "checks \(verdicts.count)/\(verdicts.count) PASS"
                : "checks FAIL: \(failed.map(\.id).joined(separator: ", "))",
            24, height - 30)
        pop()
    }

    private func emitProbes() {
        probe("view", views[viewIndex].label)
        probe("camera.azimuth", orbitCamera.azimuth)
        probe("camera.elevation", orbitCamera.elevation)
        probe("camera.distance", orbitCamera.distance)
        probe("worldScale", worldScale)
        probe("shadows", shadowsOn)
        probe("autoRotate", autoRotate)
        probe("input.buttonStateSuspect", buttonStateSuspect)
    }

    // MARK: - 入力

    func keyPressed() {
        guard let key else { return }
        switch String(key).lowercased() {
        case "1", "2", "3", "4":
            if let index = views.firstIndex(where: { $0.key == String(key) }) {
                select(index)
            }
        case "0":
            select(0)
        case "a":
            autoRotate.toggle()
        case "f":
            showFloor.toggle()
            // 床は影の受け手なので、出すときは影も点ける
            if showFloor, !shadowsOn { setShadows(true) }
        case "x":
            setShadows(!shadowsOn)
        case "s":
            savePNG(named: "insignia-\(views[viewIndex].label).png")
        case "b":
            transparentSave.toggle()
        case "h":
            showHelp.toggle()
        default:
            break
        }
    }

    private func setShadows(_ on: Bool) {
        shadowsOn = on
        if on {
            enableShadows(resolution: shadowResolution)
            shadowBias(0.0006)
        } else {
            disableShadows()
        }
    }

    private func select(_ index: Int) {
        transitionFrom = CameraPose(
            azimuth: orbitCamera.azimuth,
            elevation: orbitCamera.elevation,
            distance: orbitCamera.distance
        )
        transitionStart = time
        viewIndex = index
    }

    // MARK: - 書き出し

    /// PNG 保存。
    ///
    /// 0.13.0 の `saveFrame(_:)` は相対パスをプロジェクトルート基準で解決する
    /// （[metaphor#757](https://github.com/shinyaoguri/metaphor/issues/757) の修正後）。
    /// 以前は渡した名前に無条件で `~/Desktop/` が前置され、絶対パスは無言で捨てられていた。
    /// 対照実験のとき、条件をファイル名に残す（`INSIGNIA_SCALE=1` と影オフ）。
    private var shotSuffix: String {
        var parts: [String] = []
        if worldScale != 120 { parts.append("scale\(Int(worldScale))") }
        if shadowsOn { parts.append("shadow") }
        if transparentSave { parts.append("alpha") }
        if showFloor { parts.append("floor") }
        return parts.isEmpty ? "" : "-" + parts.joined(separator: "-")
    }

    private func savePNG(named name: String) {
        pendingSavePath = "output/\(name)"
    }

    /// 予約されたフレームを書き出す。`saveFrame` は次フレームの GPU 完了ハンドラで書くので、
    /// ここで返ってきてもファイルはまだ存在しない（"始まった" であって "終わった" ではない）。
    private func flushPendingSave() {
        guard let path = pendingSavePath else { return }
        saveFrame(path)
        print("[shot] \(path)\(transparentSave ? " (背景 α=0)" : "")")
        fflush(stdout)
        pendingSavePath = nil
    }

    /// `INSIGNIA_SHOTS=1` のとき 4 プリセットを 1 枚ずつ撮って終了する。
    /// `INSIGNIA_FRAMES=<dir>` のとき自動回転を 1 周ぶん連番 PNG で書き出す。
    private func captureIfRequested() {
        let env = ProcessInfo.processInfo.environment

        if env["INSIGNIA_SHOTS"] != nil {
            let holdFrames = 40
            let index = min(views.count - 1, (frameCount - 20) / holdFrames)
            if frameCount >= 20 {
                if index != viewIndex, !savedShots.contains(views[index].label) {
                    select(index)
                }
                let label = views[viewIndex].label
                let settled = (frameCount - 20) % holdFrames == holdFrames - 1
                if settled, !savedShots.contains(label) {
                    savedShots.insert(label)
                    savePNG(named: "insignia-\(label)\(shotSuffix).png")
                    if savedShots.count == views.count {
                        // saveFrame は次フレームの GPU 完了ハンドラで書くので、ここで即 exit すると
                        // 最後の 1 枚が出来上がる前にプロセスが消える（実際に 4 枚目を落とした）。
                        lastShotFrame = frameCount
                    }
                }
                if let last = lastShotFrame, frameCount >= last + 20 {
                    print("[shot] \(views.count) プリセット完了")
                    fflush(stdout)
                    exit(0)
                }
            }
            return
        }

        guard let directory = env["INSIGNIA_FRAMES"] else { return }
        if recordingDone, let end = recordingEndFrame, frameCount >= end + 30 { exit(0) }
        if recordingDone { return }
        // ちょうど 1 周ぶんを記録する（2π / spinPerFrame フレーム）
        let spin: Float = 0.018
        let turnFrames = Int((2 * Float.pi / spin).rounded())
        if !recording, frameCount == 30 {
            spinPerFrame = spin
            autoRotate = true
            recording = true
            beginFrameRecord(directory: directory)
            print("[frames] 記録開始 → \(directory) (\(turnFrames) フレームで 1 周)")
            fflush(stdout)
        } else if recording, frameCount >= 30 + turnFrames {
            endFrameRecord()
            recording = false
            recordingDone = true
            recordingEndFrame = frameCount
            print("[frames] 記録終了")
            fflush(stdout)
        } else if let end = recordingEndFrame, frameCount >= end + 30 {
            // 連番の書き出しも非同期なので、閉じた直後に終えると末尾が数枚落ちる
            exit(0)
        }
    }

    // MARK: - 検査の報告

    private func report(_ verdicts: [Verdict]) {
        print("── 0824-insignia 自己検査 (worldScale=\(worldScale)) ──")
        for verdict in verdicts {
            probe("check.\(verdict.id)", verdict.line)
            print("  \(verdict.id): \(verdict.line)")
        }
        let failed = verdicts.filter { !$0.passed }.count
        print("── \(verdicts.count - failed)/\(verdicts.count) PASS ──")
        fflush(stdout)
    }

    // MARK: - 補助

    private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }

    /// `a` から `b` への角度差を [-π, π] に畳む。
    private func shortestArc(_ a: Float, _ b: Float) -> Float {
        var d = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return d
    }

    private static func floatFromEnvironment(_ name: String) -> Float? {
        guard let raw = ProcessInfo.processInfo.environment[name], let value = Float(raw),
            value > 0
        else { return nil }
        return value
    }
}
