import Metal
import MetaphorSyphon
import metaphor

// MARK: - ジャックの識別子

/// 交換台のジャック 1 口 = 出力プラグイン 1 本。
///
/// `pluginID` はレンダラー側の識別子、`providerID` は ``MetaphorOutputProviders`` 側の識別子で、
/// **別の名前空間**であることに注意（metaphor#792 M1 で分かれた）。ジャックによっては
/// provider を持たない（`SketchConfig.plugins` から直接生える）ものもある。
enum Jack {
    /// 自作の出力プラグイン。**provider 経由**で自動配線される（Syphon と同じ入口）。
    static let aperture = "org.switchboard.tap.aperture"
    /// 自作の出力プラグイン。**`SketchConfig.plugins` の PluginFactory 経由**で生える。
    static let ledger = "org.switchboard.tap.ledger"
    /// 実物の Syphon。`.syphon(name:)` か `METAPHOR_SYPHON_NAME` で生える。
    /// metaphor-syphon 側の `SyphonPlugin.id`（internal なので文字列で持つ）。
    static let syphon = "org.metaphor.syphon-output"
    /// provider が常に nil を返すジャック。差し込み口だけあってコードが繋がらない。
    static let silent = "org.switchboard.tap.silent"
    /// 出力ではない通常プラグイン。出力フェーズより**前**に post() が来ることの対照。
    static let monitor = "org.switchboard.line.monitor"
    /// セカンダリウィンドウ側の出力プラグイン（`SketchWindowConfig.plugins` から生える）。
    static let window = "org.switchboard.tap.window"
}

// MARK: - 交換手の記録簿

/// `post(texture:commandBuffer:)` がフレームごとに「誰に・どの順で」来たかを溜める共有記録。
///
/// `draw()` は `post()` より前に走るので、**盤面が描いているのは常に 1 フレーム前の記録**。
/// `beginFrame(_:)` が前フレームを確定させてから新しいフレームを開ける。
@MainActor
final class OutletLog {
    static let shared = OutletLog()

    /// 1 フレーム内の 1 件の到着。
    struct Arrival {
        let id: String
        /// `MetaphorOutputPlugin` に準拠しているか（= 出力フェーズで呼ばれるはず）。
        let isOutput: Bool
        /// そのフレームで何番目に呼ばれたか（0 始まり）。
        let order: Int
        /// 受け取ったテクスチャの寸法。全員が同じ 1 枚を見ているかの裏取り。
        let size: (width: Int, height: Int)
    }

    /// 確定した直前フレームの到着順（盤面と probe が読む）。
    private(set) var settled: [Arrival] = []
    /// `settled` がどのフレームのものか。
    private(set) var settledFrame = -1
    /// id ごとの累計受信回数。
    private(set) var totals: [String: Int] = [:]
    /// id ごとに最後にフレームを受け取ったフレーム番号。
    private(set) var lastSeen: [String: Int] = [:]

    private var current: [Arrival] = []
    private var currentFrame = -1

    /// セカンダリウィンドウ側の出力プラグインが受けた回数。
    ///
    /// **主盤の到着順とは混ぜない**。レンダラーが別なので同じフレーム列に並べると
    /// 「出力フェーズが最後」の判定が 2 つのループの取り合いで壊れて読めなくなる。
    private(set) var windowTotal = 0

    func recordWindow() { windowTotal += 1 }

    /// 出力プラグインが `onAttach(renderer:)` で掴んだレンダラー。
    ///
    /// `Sketch` はレンダラーを公開していない（`context` は internal）ので、metaphor-syphon の
    /// 互換 facade（`MetaphorRenderer.syphonOutput` / `startSyphonServer` / `stopSyphonServer`）へは
    /// **プラグイン経由でしか届かない**。ジャックが 1 口でも付いていればここに入る。
    private(set) weak var renderer: MetaphorRenderer?

    func attach(renderer: MetaphorRenderer) {
        self.renderer = renderer
    }

    /// `draw()` の先頭で呼ぶ。前フレームを確定させ、新しいフレームの記録を開ける。
    func beginFrame(_ frame: Int) {
        settled = current
        settledFrame = currentFrame
        current = []
        currentFrame = frame
    }

    /// プラグインの `post()` から呼ぶ。
    func record(id: String, isOutput: Bool, texture: MTLTexture) {
        current.append(Arrival(
            id: id, isOutput: isOutput, order: current.count,
            size: (texture.width, texture.height)
        ))
        totals[id, default: 0] += 1
        lastSeen[id] = currentFrame
    }

    /// そのジャックが直前のフレームでフレームを受け取ったか（= ランプが点くか）。
    func lit(_ id: String) -> Bool {
        settled.contains { $0.id == id }
    }

    /// 直前のフレームでの到着順（0 始まり）。来ていなければ `nil`。
    func order(of id: String) -> Int? {
        settled.first { $0.id == id }?.order
    }
}

// MARK: - 出力プラグイン（ジャック）

/// 最終フレームを受け取ったことだけを記録する出力プラグイン。
///
/// `MetaphorOutputPlugin` は post() を**通常プラグインの後**に回すためだけのマーカー
/// （metaphor 0.13.0 時点で追加の要件は無い）。Syphon / NDI と同じ席に着く。
@MainActor
final class TapPlugin: MetaphorOutputPlugin {
    let pluginID: String

    init(id: String) {
        self.pluginID = id
    }

    func onAttach(renderer: MetaphorRenderer) {
        OutletLog.shared.attach(renderer: renderer)
    }

    func post(texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        OutletLog.shared.record(id: pluginID, isOutput: true, texture: texture)
    }
}

/// 出力**ではない**通常プラグイン。出力フェーズの境界を測るための対照。
///
/// 同じ `plugins:` 配列に入れても、`MetaphorOutputPlugin` に準拠していないので
/// post() は出力より前に来るはず（metaphor の MetaphorRenderer が 2 周に分けて呼ぶ）。
@MainActor
final class LineMonitorPlugin: MetaphorPlugin {
    let pluginID = Jack.monitor

    func post(texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        OutletLog.shared.record(id: pluginID, isOutput: false, texture: texture)
    }
}

/// セカンダリウィンドウ側のジャック。主盤の到着順とは別に数える。
@MainActor
final class WindowTapPlugin: MetaphorOutputPlugin {
    let pluginID = Jack.window

    func post(texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        OutletLog.shared.recordWindow()
    }
}

// MARK: - 出力 provider

/// `TapPlugin` を 1 本返す provider。Syphon と同じ自動配線の入口を自作側でも通す。
struct TapProvider: MetaphorOutputProvider {
    let id: String
    let pluginID: String
    let requirements: PluginRequirements

    @MainActor
    func makeOutput(context: MetaphorOutputContext) -> MetaphorOutputPlugin? {
        // セカンダリウィンドウには出さない（metaphor-syphon の SyphonOutputProvider と同じ判断）。
        guard case .primary = context.scope else { return nil }
        return TapPlugin(id: pluginID)
    }
}

/// 常に `nil` を返す provider。**登録はされているが、この起動では出力しない**という状態を作る。
///
/// `requirements` を書かないので、protocol extension の既定値（空）が効いているかの確認も兼ねる。
struct SilentProvider: MetaphorOutputProvider {
    let id = "org.switchboard.provider.silent"

    @MainActor
    func makeOutput(context: MetaphorOutputContext) -> MetaphorOutputPlugin? { nil }
}

/// 検査で使う、名前だけの provider（出力は返さない）。
struct DummyProvider: MetaphorOutputProvider {
    let id: String
    let requirements: PluginRequirements

    init(id: String, requirements: PluginRequirements = []) {
        self.id = id
        self.requirements = requirements
    }

    @MainActor
    func makeOutput(context: MetaphorOutputContext) -> MetaphorOutputPlugin? { nil }
}
