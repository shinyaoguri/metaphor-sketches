import AppKit
import Foundation
import metaphor

/// 三連祭壇画を実際に「並べる」ための当て木。
///
/// `SketchWindowConfig` にはウィンドウの位置を指定する口が無く、既定は 30px のカスケードだけ
/// （[metaphor#837](https://github.com/shinyaoguri/metaphor/issues/837)）。
/// 三連祭壇画は左翼・中央・右翼が横に並んで初めて 1 枚の絵になるので、
/// metaphor の外へ降りて AppKit で置く。
///
/// **判定 W7 はこれを当てる前に取る**ので、metaphor 自身の配置がどうなるかは記録に残る。
/// `TRIPTYCH_ARRANGE=0` で当て木を外せば、カスケードのまま散らばった状態を見られる。
@MainActor
enum AltarArrangement {
    static let disabled = ProcessInfo.processInfo.environment["TRIPTYCH_ARRANGE"] == "0"

    /// 左翼 → 中央 → 右翼 の順に、主ディスプレイの中央へ隙間なく並べる。
    /// - Returns: 3 枚を囲む矩形（画面座標、左下原点）。撮影範囲として使う。
    @discardableResult
    static func apply(order titles: [String]) -> NSRect? {
        guard !disabled else { return nil }
        let windows = titles.compactMap { title in
            NSApplication.shared.windows.first { $0.title == title && $0.isVisible }
        }
        guard windows.count == titles.count, let screen = NSScreen.main else { return nil }

        let totalWidth = windows.reduce(0) { $0 + $1.frame.width }
        let maxHeight = windows.map(\.frame.height).max() ?? 0
        var x = screen.visibleFrame.midX - totalWidth / 2
        let y = screen.visibleFrame.midY - maxHeight / 2

        for w in windows {
            // 高さが違っても下辺を揃える（この作品は 3 枚とも同じ高さになる）
            w.setFrameOrigin(NSPoint(x: x, y: y))
            x += w.frame.width
        }
        return NSRect(x: screen.visibleFrame.midX - totalWidth / 2, y: y,
                      width: totalWidth, height: maxHeight)
    }
}

/// 世界のどこを切り出す板か。
struct Panel {
    let name: String
    let origin: Float
    let width: Float
}

/// パネルを跨いで共有する状態。**中央（プライマリ）だけが書き換え、翼は読むだけ。**
///
/// 翼のレンダーループは中央と非同期に回るので、翼の描画クロージャからここを触ると
/// 「中央が最後に置いた値」を読むことになる。時計もそれで運ぶ（`clock`）。
@MainActor
final class Stage {
    /// 中央が毎フレーム進める共有時計。3 枚の板はこれを見て同じ時刻を描く。
    var clock: Float = 0

    /// 世界座標に置かれた灯。クリックで増える。
    var lanterns: [SIMD2<Float>] = []

    var marchers: [World.Marcher] = []

    /// 翼ごとの計測結果。キーは翼の名前。
    var meters: [String: PanelMeter] = [:]

    /// 翼を自分の時計（`ctx.time`）で描くか。`TRIPTYCH_CLOCK=own` で有効。
    /// 既定（共有時計）との差が S3 の実測値になる。
    let useOwnClock = ProcessInfo.processInfo.environment["TRIPTYCH_CLOCK"] == "own"

    func addLantern(_ p: SIMD2<Float>) {
        lanterns.append(p)
        if lanterns.count > 14 { lanterns.removeFirst() }
    }
}

/// 1 枚の翼が、自分のレンダーループで回りながら残す計測値。
///
/// 見たいのは絶対値ではなく **ずれの変化**。生成タイミングの差で最初から一定のオフセットが
/// あるのは当然なので、初回の差を基準にして、そこからどれだけ離れていくかを見る。
@MainActor
final class PanelMeter {
    private(set) var frames = 0
    private(set) var firstDelta: Float?
    private(set) var lastDelta: Float = 0
    private(set) var maxDrift: Float = 0
    private(set) var lastOwnTime: Float = 0
    private(set) var lastOwnFrameCount = 0

    /// 翼が 1 フレーム描くたびに呼ぶ。`own` は翼自身の `ctx.time`、`shared` は中央の時計。
    func sample(own: Float, ownFrameCount: Int, shared: Float) {
        frames += 1
        lastOwnTime = own
        lastOwnFrameCount = ownFrameCount
        let d = own - shared
        if firstDelta == nil { firstDelta = d }
        lastDelta = d
        maxDrift = max(maxDrift, abs(d - (firstDelta ?? d)))
    }

    var driftMs: Float { maxDrift * 1000 }
    var lastDeltaMs: Float { lastDelta * 1000 }
    var offsetMs: Float { (firstDelta ?? 0) * 1000 }
}

/// 翼（セカンダリウィンドウ）の一式。開閉のたびに作り直される。
@MainActor
final class Wing {
    let panel: Panel
    let config: SketchWindowConfig
    private(set) var window: SketchWindow?

    init(panel: Panel, config: SketchWindowConfig) {
        self.panel = panel
        self.config = config
    }

    var isOpen: Bool { window?.isOpen ?? false }

    /// 翼を開き、この翼ぶんの描画クロージャを据える。
    ///
    /// `onDraw(_:)` は 1 回設定すれば毎フレーム走る（`draw(_:)` と同じ保存セマンティクス）。
    /// 毎フレーム設定し直す必要はない — ここは doc の主張どおりかを L2 で確かめる。
    @discardableResult
    func open(with make: (SketchWindowConfig) -> SketchWindow?, stage: Stage) -> SketchWindow? {
        guard window?.isOpen != true else { return window }
        // `make` は当て木込みでウィンドウを作る（App 側の makeWindow(_:)）。
        guard let w = make(config) else { return nil }
        window = w

        let panel = self.panel
        let meter = PanelMeter()
        stage.meters[panel.name] = meter

        w.onDraw { [weak stage] ctx in
            guard let stage else { return }
            meter.sample(own: ctx.time, ownFrameCount: ctx.frameCount, shared: stage.clock)
            let clock = stage.useOwnClock ? ctx.time : stage.clock
            World.render(into: ctx, panel: panel, clock: clock, stage: stage)
        }

        // 入力コールバックは「メソッド」ではなく代入するプロパティ（`onDraw` と形が違う）。
        w.onMouseClicked = { [weak stage] win in
            guard let stage else { return }
            let wx = panel.origin + win.input.mouseX
            stage.addLantern(SIMD2(wx, win.input.mouseY))
            Log.line("[入力] \(panel.name) クリック → 翼ローカル (\(fmt(win.input.mouseX)), \(fmt(win.input.mouseY))) / 世界 x=\(fmt(wx))")
        }
        return w
    }

    func close() {
        window?.close()
        window = nil
    }
}

/// 祭壇画の構え。世界の切り分けと、翼の開閉の段取りを持つ。
@MainActor
enum Altar {
    /// 中央（プライマリ）は 1280×720、翼は 800×720。合わせて世界幅 2880。
    static let centerWidth: Float = 1280
    static let wingWidth: Float = 800

    static let center = Panel(name: "中央 — 祭壇", origin: wingWidth, width: centerWidth)
    static let leftPanel = Panel(name: "左翼 — 出立", origin: 0, width: wingWidth)
    static let rightPanel = Panel(name: "右翼 — 到着", origin: wingWidth + centerWidth, width: wingWidth)

    /// 翼を閉じてまた開くまでの 1 巡（秒）。ソークで最低 2 巡は回るようにここを決める。
    static let cycle: Float = 42
    /// 1 巡のうち翼が開いている秒数。
    static let openFor: Float = 30

    /// `TRIPTYCH_WINGS=<n>` で翼の枚数を振る（既定 2）。3 枚目以降は左翼と同じ範囲を映す
    /// 「複製の翼」で、枚数だけを増やして規模由来の穴を見るための口。
    static var wingCount: Int {
        guard let raw = ProcessInfo.processInfo.environment["TRIPTYCH_WINGS"],
              let n = Int(raw), n >= 0, n <= 12
        else { return 2 }
        return n
    }

    /// 連番を書き出しているときに 3 枚へ揃える fps。書き出していなければ nil。
    static var recordingFPS: Int? {
        ProcessInfo.processInfo.environment["TRIPTYCH_FRAMES"] == nil ? nil : 20
    }

    static func makeWings() -> [Wing] {
        var wings: [Wing] = []
        let n = wingCount
        for i in 0..<n {
            let isLeft = i % 2 == 0
            let base = isLeft ? leftPanel : rightPanel
            let suffix = i < 2 ? "" : " (\(i / 2 + 1))"
            let panel = Panel(name: base.name + suffix, origin: base.origin, width: base.width)
            // 左翼は 30fps、右翼は 60fps。frameCount の比 (≈0.5) が S2 の実測値になる。
            // windowScale 0.5 は「ウィンドウ実寸 ≠ テクスチャ寸法」を作り、S4 の座標変換を試すため。
            //
            // ただし連番の書き出し中は 3 枚とも同じ fps に落とす。PNG の書き出しが重くて
            // 目標 fps に追いつかないと、**連番の番号と時刻の対応が panel ごとに崩れる**。
            // その状態で番号を揃えて GIF を作ると、揃っているはずの継ぎ目が跳んで見える
            // (実際に一度それで 0.5 秒ずれた GIF を作りかけた)。
            let config = SketchWindowConfig(
                width: Int(base.width),
                height: Int(World.height),
                title: "triptych — \(panel.name)",
                fps: recordingFPS ?? (isLeft ? 30 : 60),
                windowScale: 0.5
            )
            wings.append(Wing(panel: panel, config: config))
        }
        return wings
    }

    /// この時刻で翼は開いているべきか。
    static func shouldBeOpen(at clock: Float) -> Bool {
        World.wrapPositive(clock, cycle) < openFor
    }
}

/// 標準出力へ出す観測ログ。
///
/// **`print` は `fflush(stdout)` とセットで。** パイプへ流すとブロックバッファされ、
/// 「動いていない」と誤診する（#10 で実際に一度誤診した）。
enum Log {
    static func line(_ s: String) {
        print(s)
        fflush(stdout)
    }
}

func fmt(_ v: Float, _ digits: Int = 1) -> String {
    String(format: "%.\(digits)f", v)
}
