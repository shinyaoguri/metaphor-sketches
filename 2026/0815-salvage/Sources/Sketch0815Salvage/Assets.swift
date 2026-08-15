import Foundation
import metaphor

/// バンドル内のリソースパス解決。
///
/// `Package.swift` は `.copy("Resources")` で宣言している（`.process` はサブディレクトリ
/// 構成を保証しない）。Examples の流儀（`inDirectory:`）に合わせる。
enum Res {
    static func path(_ name: String, _ ext: String, in dir: String) -> String? {
        Bundle.module.path(forResource: name, ofType: ext, inDirectory: "Resources/\(dir)")
    }
}

/// 何がロードされ、何が解放されたかの台帳。
///
/// **寿命境界の観測点**。ライブラリ側に「いま生きているアセット」を答える API が
/// 無いので、作品側で数える。Probe に出して、ソーク中に残高が増え続けないかを見る。
@MainActor
final class AssetLedger {
    private(set) var loads = 0
    private(set) var unloads = 0
    private(set) var live = 0
    private(set) var lastLoadMillis: Double = 0
    private(set) var totalLoadMillis: Double = 0
    /// ロードに失敗したもの（名前）。無言で消える絵を後から追えるようにする。
    private(set) var failures: [String] = []

    func didLoad(_ count: Int, millis: Double) {
        loads += count
        live += count
        lastLoadMillis = millis
        totalLoadMillis += millis
    }

    func didUnload(_ count: Int) {
        unloads += count
        live -= count
    }

    func didFail(_ name: String) {
        if !failures.contains(name) { failures.append(name) }
    }
}

/// 全ステージで共有するアセット。起動時に 1 度だけ読み、最後まで生かす。
///
/// ステージ固有アセット（`StageAssets`）との対照。寿命境界の議論で
/// 「シーンをまたいで生きるもの」と「シーンと心中するもの」を分けて扱えるかを見る。
@MainActor
final class SharedAssets {
    let drone: Mesh?
    let core: Mesh?
    let beacon: Mesh?
    let pickup: SoundFile?
    let hit: SoundFile?

    init(sketch: any Sketch, ledger: AssetLedger) {
        func model(_ name: String) -> Mesh? {
            guard let path = Res.path(name, "obj", in: "Models") else {
                ledger.didFail("Models/\(name).obj")
                return nil
            }
            // normalize は既定 true（原点中心・最大辺 2 単位へ潰す）。描画側で
            // scale を与える前提なのでそのまま受ける。
            guard let mesh = sketch.loadModel(path) else {
                ledger.didFail("Models/\(name).obj (parse)")
                return nil
            }
            return mesh
        }

        func sound(_ name: String) -> SoundFile? {
            guard let path = Res.path(name, "wav", in: "Sounds") else {
                ledger.didFail("Sounds/\(name).wav")
                return nil
            }
            return try? sketch.loadSound(path)
        }

        let started = Date()
        drone = model("drone")
        core = model("core")
        beacon = model("beacon")
        pickup = sound("se_pickup")
        hit = sound("se_hit")
        let millis = Date().timeIntervalSince(started) * 1000

        let count = [drone != nil, core != nil, beacon != nil, pickup != nil, hit != nil]
            .filter { $0 }.count
        ledger.didLoad(count, millis: millis)
    }
}

/// 1 ステージ分のアセット束。**シーンの寿命と一致する**のがこの型の主張。
///
/// `init` はシーンの enter、`unload()` は exit から呼ぶ。ライブラリのキャッシュ
/// （`loadModel(cache:)` / `loadImage(cache:)`）を使うと解放が効かなくなるため、
/// 既定は `cache: false`。`SALVAGE_ASSET_CACHE=1` で既定どおり（cache: true）に
/// 切り替えられる — ソークで両者を比較して #571 の判定材料にするため。
@MainActor
final class StageAssets {
    let spec: StageSpec
    private(set) var obstacle: Mesh?
    private(set) var floor: MImage?
    private(set) var ambience: SoundFile?
    private(set) var backdrop: VideoPlayer?
    private(set) var loadMillis: Double = 0
    private var liveCount = 0
    private unowned let ledger: AssetLedger

    static let useLibraryCache = Env.bool("SALVAGE_ASSET_CACHE")

    init(spec: StageSpec, sketch: any Sketch, ledger: AssetLedger) {
        self.spec = spec
        self.ledger = ledger

        let cache = StageAssets.useLibraryCache
        let started = Date()

        if let path = Res.path(spec.obstacleModel, "obj", in: "Models") {
            obstacle = sketch.loadModel(path, cache: cache)
            if obstacle == nil { ledger.didFail("Models/\(spec.obstacleModel).obj") }
        } else {
            ledger.didFail("Models/\(spec.obstacleModel).obj")
        }

        if let path = Res.path(spec.floorImage, "png", in: "Images") {
            floor = try? sketch.loadImage(path, cache: cache)
            if floor == nil { ledger.didFail("Images/\(spec.floorImage).png") }
        } else {
            ledger.didFail("Images/\(spec.floorImage).png")
        }

        if let path = Res.path(spec.ambienceSound, "wav", in: "Sounds") {
            ambience = try? sketch.loadSound(path)
            if ambience == nil { ledger.didFail("Sounds/\(spec.ambienceSound).wav") }
        } else {
            ledger.didFail("Sounds/\(spec.ambienceSound).wav")
        }

        if let name = spec.backdropVideo {
            if let path = Res.path(name, "mp4", in: "Videos") {
                backdrop = try? sketch.loadVideo(path)
                if backdrop == nil { ledger.didFail("Videos/\(name).mp4") }
            } else {
                ledger.didFail("Videos/\(name).mp4")
            }
        }

        loadMillis = Date().timeIntervalSince(started) * 1000
        liveCount = [obstacle != nil, floor != nil, ambience != nil, backdrop != nil]
            .filter { $0 }.count
        ledger.didLoad(liveCount, millis: loadMillis)
    }

    /// 再生を止めて参照を落とす。
    ///
    /// **音と動画は参照を捨てるだけでは止まらない**（内部で AVAudioEngine / AVPlayer が
    /// 回り続ける）。作者が明示的に stop を呼ばなければならない、というのがこの作品で
    /// 一番はっきり出た「寿命境界が要る」根拠。
    func unload() {
        ambience?.stop()
        backdrop?.stop()
        obstacle = nil
        floor = nil
        ambience = nil
        backdrop = nil
        ledger.didUnload(liveCount)
        liveCount = 0
    }

    func beginPlayback(volume: Float) {
        ambience?.gain = volume
        ambience?.loop()
        backdrop?.isLooping = true
        backdrop?.gain = 0
        backdrop?.play()
    }

    func updatePlayback() {
        backdrop?.update()
    }
}
