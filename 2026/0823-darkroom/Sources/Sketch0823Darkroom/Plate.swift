import Foundation
import metaphor

// MARK: - 原版

/// 原版（ネガ）。**3 つの窓が同じこれを描く。**
///
/// 絵であると同時に**測定信号**として設計してある。3 本の Syphon を外から受け取ったとき、
/// 受け手が絵を見ずに次の 2 つを数値で言えるようにするのが狙い:
///
/// - **どの槽の絵か**（取り違えていないか）— ステップウェッジの平均輝度と、粒のエッジ量
/// - **同じ瞬間か**（連動しているか）— 露光時計の針の角度
///
/// どちらも現像（ポストエフェクト）を通り抜けても読める量を選んである。sobel は面を落として
/// 輪郭だけ残すが**針の向きは残る**し、dilate は太らせるが**向きは変えない**。
enum Plate {
    /// 原版の寸法。Syphon で外へ出すので FHD 固定（窓の表示だけ `windowScale` で縮める）。
    static let width: Float = 1920
    static let height: Float = 1080

    /// 露光時計が 1 周する秒数。針の角度から時刻が逆算できる。
    static let clockPeriod: Float = 8

    /// 針の長さ（中心から先端まで）。
    static let handLength: Float = 360

    /// ステップウェッジの段数。
    static let wedgeSteps = 11

    /// ステップウェッジの帯の高さ。
    static let wedgeHeight: Float = 96

    /// ステップウェッジだけを平均したときの期待輝度（0…255）。
    ///
    /// 段 `i` の輝度は `i / (steps - 1) * 255` なので、平均は段番号の平均 = ちょうど中央値。
    /// **metaphor を呼ばずに手で解ける値**なので、読み戻した実測と突き合わせられる。
    static var wedgeExpectedLuma: Float { 255 * 0.5 }

    // MARK: - 描画

    /// 原版を 1 枚描く。
    ///
    /// `ctx` は窓ごとに違う（プライマリは自分の `context`、セカンダリは `onDraw` が渡すもの）が、
    /// **`room` は 1 つしかない**。だから 3 枚は同じ状態の同じ瞬間を描く ＝ 連動する。
    /// 違うのはこの後に掛かる現像（ポストエフェクト）だけ。
    @MainActor
    static func render(into ctx: SketchContext, bath: Bath, room: Darkroom) {
        let clock = room.clock
        let phase = room.phase

        // 暗室の安全光。赤みを残した暗がりで、粒と針だけが浮く。
        ctx.background(16, 7, 8)
        drawSafelight(ctx, clock: clock)

        drawGrains(ctx, room: room, clock: clock, phase: phase)
        drawWedge(ctx, phase: phase)
        drawClockFace(ctx, clock: clock)
        drawPlaque(ctx, bath: bath, room: room)
    }

    /// 安全光。赤い灯が 1 つ、天井の隅で息をしている。
    ///
    /// 同心円を重ねただけの滲みだが、**画面に「暗室である」ことを言わせる**のはこれ。
    /// 中心を外してあるので、3 枚に同じ滲みが乗ることで連動も目で分かる。
    @MainActor
    private static func drawSafelight(_ ctx: SketchContext, clock: Float) {
        let cx = width * 0.16
        let cy = height * 0.2
        let breath = 0.86 + 0.14 * sin(clock * 0.7)
        ctx.noStroke()
        for i in stride(from: 12, through: 1, by: -1) {
            let r = Float(i) * 78 * breath
            let a = 9 - Float(i) * 0.55
            ctx.fill(150, 26, 22, max(a, 1.2))
            ctx.circle(cx, cy, r * 2)
        }
    }

    /// 銀塩の粒。**現像槽の効きが目で分かる粒度**にしてある（細かすぎると sobel が拾えない）。
    ///
    /// 位置は `Darkroom` が最初に 1 回だけ決めた決定論的な配列で、毎フレーム同じ。
    /// 明滅だけが時間で変わるので、フレーム間の差は「露光量」だけになる。
    @MainActor
    private static func drawGrains(
        _ ctx: SketchContext, room: Darkroom, clock: Float, phase: Phase
    ) {
        ctx.noStroke()
        let exposure = phase.exposure
        for g in room.grains {
            // 粒ごとに少しずつ違う速さで瞬く。位相は粒の座標から決まるので決定論的。
            let flicker = 0.55 + 0.45 * sin(clock * g.rate + g.phase)
            let v = g.brightness * flicker * exposure
            ctx.fill(v * 0.92, v * 0.86, v * 0.78, 235)
            ctx.circle(g.x, g.y, g.size)
        }
    }

    /// ステップウェッジ（濃度の階段）。下辺に敷く帯。
    ///
    /// **期待値を手で解けることが取り柄**なので、段の作り方は素直に保つ
    /// （段幅 = 幅 / 段数、段 i の輝度 = i / (段数 - 1)）。
    @MainActor
    private static func drawWedge(_ ctx: SketchContext, phase: Phase) {
        let stepW = width / Float(wedgeSteps)
        let y = height - wedgeHeight
        ctx.noStroke()
        for i in 0..<wedgeSteps {
            let v = Float(i) / Float(wedgeSteps - 1) * 255
            ctx.fill(v, v, v)
            ctx.rect(Float(i) * stepW, y, stepW, wedgeHeight)
        }
        // 工程を示す細い線。段の上に 1 本だけ引く（測定量には効かない太さ）。
        ctx.stroke(phase.tint.0, phase.tint.1, phase.tint.2)
        ctx.strokeWeight(4)
        ctx.line(0, y - 8, width * phase.progress, y - 8)
        ctx.noStroke()
    }

    /// 露光時計。**針の角度が「いま何時か」＝ 3 本が連動しているかの一次証拠**になる。
    ///
    /// 針を太く長くしてあるのは、sobel で輪郭だけになっても dilate で太っても、
    /// 受け手側で主軸として拾えるようにするため。
    @MainActor
    private static func drawClockFace(_ ctx: SketchContext, clock: Float) {
        let cx = width * 0.5
        let cy = (height - wedgeHeight) * 0.5

        // 文字盤の目盛り。12 本。
        ctx.stroke(178, 120, 116)
        ctx.strokeWeight(5)
        for i in 0..<12 {
            let a = Float(i) / 12 * Float.pi * 2
            let r0 = handLength + 24
            let r1 = handLength + 56
            ctx.line(cx + cos(a) * r0, cy + sin(a) * r0, cx + cos(a) * r1, cy + sin(a) * r1)
        }

        // 針。角度は共有時計だけで決まる（窓ごとの ctx.time は使わない）。
        let angle = handAngle(at: clock)
        ctx.pushMatrix()
        ctx.translate(cx, cy)
        ctx.rotate(angle)
        ctx.noStroke()
        ctx.fill(250, 244, 232)
        ctx.rect(-18, -18, handLength, 36)
        ctx.circle(0, 0, 64)
        ctx.popMatrix()
    }

    /// 針の角度（ラジアン）。受け手が読んだ角度から時刻を逆算するときも同じ式を使う。
    static func handAngle(at clock: Float) -> Float {
        let t = clock.truncatingRemainder(dividingBy: clockPeriod) / clockPeriod
        return t * Float.pi * 2
    }

    /// 額の銘板。どの槽か・いま何工程目か・何フレーム目かを人が読めるように置く。
    @MainActor
    private static func drawPlaque(_ ctx: SketchContext, bath: Bath, room: Darkroom) {
        ctx.noStroke()
        ctx.fill(232, 226, 214)
        ctx.textSize(34)
        ctx.text("\(bath.label)", 48, 66)
        ctx.textSize(22)
        ctx.text("syphon: \(bath.syphonName)", 48, 104)
        ctx.text("\(room.phase.name)  frame \(room.frame)", 48, 136)
    }
}

// MARK: - 工程

/// 現像の工程。1 巡 `Phase.cycle` 秒で 4 つを回る。
///
/// 巡回を持たせてあるのは、**放っておくだけでライフサイクルの経路を通し続けるため**
/// （槽の付け外し・露光量の変化）。ソークはこの巡回が最低 2 巡入る秒数で回す。
enum Phase: Int, CaseIterable {
    case exposure   // 露光 — 原版が明るくなる
    case develop    // 現像 — 槽が効く
    case stop       // 停止 — 槽を外す（3 窓とも原版に戻る）
    case fix        // 定着 — 槽を入れ直す

    /// 1 工程の長さ（秒）。
    ///
    /// 連番を録るときだけ短くする。**槽が入って外れるところまでが作品の主題**なので、
    /// 20 数秒の録画に 1 巡が入らないと、動きの証跡として意味を成さない。
    static var span: Float { Bath.isRecording ? 4 : 15 }
    /// 1 巡の長さ（秒）。
    static var cycle: Float { span * Float(allCases.count) }

    static func at(_ clock: Float) -> Phase {
        let t = clock.truncatingRemainder(dividingBy: cycle)
        let i = Int(t / span) % allCases.count
        return Phase(rawValue: i) ?? .exposure
    }

    var name: String {
        switch self {
        case .exposure: return "露光"
        case .develop: return "現像"
        case .stop: return "停止"
        case .fix: return "定着"
        }
    }

    /// 粒の明るさに掛かる係数。露光で明るく、定着で落ち着く。
    var exposure: Float {
        switch self {
        case .exposure: return 1.0
        case .develop: return 0.9
        case .stop: return 0.75
        case .fix: return 0.85
        }
    }

    /// **この工程で槽（ポストエフェクト）を掛けるか。**
    ///
    /// `stop` だけ外す。3 窓が同じ絵に戻るので、「3 本が別物である」ことの**対照**になる
    /// （槽ありのときだけ違うのなら、違いは確かに槽が作っている）。
    var bathsEngaged: Bool { self != .stop }

    var tint: (Float, Float, Float) {
        switch self {
        case .exposure: return (255, 196, 120)
        case .develop: return (120, 220, 255)
        case .stop: return (200, 200, 200)
        case .fix: return (170, 255, 190)
        }
    }

    /// 工程内の進み（0…1）。銘板の下の線の長さ。
    var progress: Float { 1 }
}

// MARK: - 共有状態

/// 3 つの窓が共有する暗室の状態。**プライマリだけが書き換え、槽は読むだけ。**
///
/// セカンダリのレンダーループはプライマリと非同期に回るので、槽の描画クロージャから
/// ここを読むと「プライマリが最後に置いた値」が返る。時計もそれで運ぶ（`clock`）。
@MainActor
final class Darkroom {
    /// プライマリが毎フレーム進める共有時計。3 枚はこれを見て同じ時刻を描く。
    var clock: Float = 0
    /// プライマリのフレーム番号。
    var frame: Int = 0

    /// いまの工程。
    var phase: Phase = .exposure

    /// 槽ごとの計測（クロック差・フレーム数）。キーは槽の名前。
    var meters: [String: BathMeter] = [:]

    /// 銀塩の粒。決定論的に 1 回だけ作る。
    let grains: [Grain]

    /// 槽を自分の時計（`ctx.time`）で描くか。`DARKROOM_CLOCK=own` で有効。
    /// 既定（共有時計）との差が、連動の検査の対照になる。
    let useOwnClock = ProcessInfo.processInfo.environment["DARKROOM_CLOCK"] == "own"

    init() {
        grains = Grain.field(count: 900)
    }
}

/// 銀塩の粒 1 つ。
struct Grain {
    let x: Float
    let y: Float
    let size: Float
    let brightness: Float
    let rate: Float
    let phase: Float

    /// 決定論的な粒の場。**実行のたびに同じ配置になる**（検査が実行ごとに揺れないように）。
    static func field(count: Int) -> [Grain] {
        var rng = SplitMix(seed: 0x0823_DA12)
        var out: [Grain] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            let x = rng.next(0, Plate.width)
            // ステップウェッジの帯には粒を置かない（測定量を濁さないため）。
            let y = rng.next(40, Plate.height - Plate.wedgeHeight - 24)
            out.append(Grain(
                x: x, y: y,
                size: rng.next(8, 34),
                brightness: rng.next(70, 245),
                rate: rng.next(0.6, 2.4),
                phase: rng.next(0, Float.pi * 2)
            ))
        }
        return out
    }
}

/// 決定論的な乱数（SplitMix64）。`Float.random` と違い**種を固定すれば毎回同じ**。
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next(_ lo: Float, _ hi: Float) -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        let unit = Float(z >> 40) / Float(1 << 24)
        return lo + unit * (hi - lo)
    }
}

// MARK: - 計測

/// 1 つの槽が自分のレンダーループで回りながら残す計測値。
///
/// 見たいのは絶対値ではなく**ずれの変化**。生成タイミングの差で最初から一定のオフセットが
/// あるのは当然なので、初回の差を基準にしてそこからどれだけ離れるかを見る
/// （0816-triptych の `PanelMeter` と同じ考え方。あちらの実測は 10–17 ms）。
@MainActor
final class BathMeter {
    private(set) var frames = 0
    fileprivate(set) var firstDelta: Float?
    private(set) var lastDelta: Float = 0
    fileprivate(set) var maxDrift: Float = 0
    private(set) var lastOwnTime: Float = 0
    private(set) var lastOwnFrameCount = 0
    /// この槽が描いた時点でプライマリが置いていたフレーム番号。
    private(set) var lastSharedFrame = 0

    func sample(own: Float, ownFrameCount: Int, shared: Float, sharedFrame: Int) {
        frames += 1
        lastOwnTime = own
        lastOwnFrameCount = ownFrameCount
        lastSharedFrame = sharedFrame
        let d = own - shared
        if firstDelta == nil { firstDelta = d }
        lastDelta = d
        maxDrift = max(maxDrift, abs(d - (firstDelta ?? d)))
    }

    /// 基準を取り直す。
    ///
    /// **`loadPixels()` は GPU の完了を待つあいだメインスレッドを止める**ので、その 1 回で
    /// 槽のレンダーループも数百 ms 止まり、drift に自分の検査ぶんのスパイクが乗る
    /// （初回の実測では 399.4 ms。これは metaphor のずれではなく、こちらが作ったずれ）。
    /// 読み戻しを伴う検査が済んでから基準を取り直して、そこから先だけを D8 の材料にする。
    func rebase() {
        firstDelta = nil
        maxDrift = 0
    }

    var driftMs: Float { maxDrift * 1000 }
    var lastDeltaMs: Float { lastDelta * 1000 }
    var offsetMs: Float { (firstDelta ?? 0) * 1000 }
}

// MARK: - 共通

/// 標準出力へ出す観測ログ。
///
/// **`print` は `fflush(stdout)` とセットで。** パイプへ流すとブロックバッファされ、
/// 「動いていない」と誤診する。
enum Log {
    static func line(_ s: String) {
        print(s)
        fflush(stdout)
    }
}

func fmt(_ v: Float, _ digits: Int = 1) -> String {
    String(format: "%.\(digits)f", v)
}
