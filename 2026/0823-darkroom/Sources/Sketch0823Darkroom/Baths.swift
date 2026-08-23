import AppKit
import Foundation
import Metal
import MetaphorMPS
import MetaphorSyphon
import metaphor

// MARK: - 槽

/// 現像槽 1 つ ＝ 窓 1 枚 ＝ Syphon 1 本。
///
/// 原版は 3 つとも同じ。**違うのはこの槽（ポストエフェクト）だけ**なので、
/// 3 本の Syphon に出る絵の違いは、そのまま槽が作った違いになる。
struct Bath {
    /// 検査 ID や Syphon 名に使う短い識別子。
    let id: String
    /// 銘板に出す名前。
    let label: String
    /// Syphon サーバー名。**セカンダリでは `SketchWindowConfig.plugins` にこれを宣言するしか口が無い**
    /// （`METAPHOR_SYPHON_NAME` はプライマリにしか効かない = `D3` で確かめる）。
    let syphonName: String
    /// 槽の中身。
    let recipe: Recipe

    /// 槽の処方。metaphor 本体ではなく **MetaphorMPS** の `PostEffect` を使う。
    enum Recipe {
        /// 素通し。原版そのもの。
        case plain
        /// 輪郭だけ残す（`MPSSobelEffect`）。
        case edge
        /// 太らせて眠らせる（`MPSDilateEffect` → `MPSBlurEffect`）。
        case bloom

        /// この処方のポストエフェクト列を組む。**呼ぶたびに新しい実体**を返す
        /// （工程が巡るたびに付け外しするので、使い回すと外した実体を再登録することになる）。
        @MainActor
        func makeEffects() -> [any PostEffect] {
            switch self {
            case .plain:
                return []
            case .edge:
                return [MPSSobelEffect()]
            case .bloom:
                return [MPSDilateEffect(radius: 5), MPSBlurEffect(sigma: 4.5)]
            }
        }

        /// 読み戻したときに期待される、原版に対する平均輝度の向き。
        ///
        /// sobel は面を落として輪郭だけ残すので**暗くなる**、dilate は明るい側へ太らせるので
        /// **明るくなる**。`D10` はこれを実測と突き合わせる。
        var expectedLumaDirection: String {
            switch self {
            case .plain: return "="
            case .edge: return "<"
            case .bloom: return ">"
            }
        }
    }

    /// 名前を省略した `.syphon()` を使うか（`DARKROOM_ANON=1`）。
    ///
    /// セカンダリには `Sketch` が無いので `onAttach(sketch:)` が呼ばれず、
    /// **名前はプロセス名へ落ちる**（metaphor-syphon の doc の主張）。3 つの窓が同じ名前を
    /// 名乗ったときに何が起きるかを `D4` で実測するための口。
    static let anonymous = ProcessInfo.processInfo.environment["DARKROOM_ANON"] == "1"

    /// この槽の Syphon 出力の宣言。
    var syphonFactory: PluginFactory {
        Self.anonymous ? .syphon() : .syphon(name: syphonName)
    }

    /// 3 つの槽。A はプライマリ、B と C は `createWindow` で開く。
    static let all: [Bath] = [
        Bath(id: "A", label: "A ─ 原版", syphonName: "darkroom - A", recipe: .plain),
        Bath(id: "B", label: "B ─ 輪郭", syphonName: "darkroom - B", recipe: .edge),
        Bath(id: "C", label: "C ─ 肉付け", syphonName: "darkroom - C", recipe: .bloom),
    ]

    static var primary: Bath { all[0] }
    static var secondaries: [Bath] { Array(all.dropFirst()) }

    /// セカンダリ窓の構成。
    ///
    /// `windowScale` は **表示だけ**を縮める。Syphon へ出るのは `width` × `height`
    /// のオフスクリーンテクスチャそのままなので、3 枚並べても FHD で publish される。
    /// 連番を書き出すときの目標 fps。
    ///
    /// **プライマリだけ `frameRate()` を落としても揃わない。** 窓は自分の `config.fps` で回るので、
    /// 書き出しの重さで落ち方が窓ごとに変わり、同じ番号のフレームが同じ瞬間でなくなる
    /// （実測: A=144 / B=240 / C=98 枚。番号で並べた GIF に無いはずの継ぎ目が出る）。
    /// 12fps でも 1920×1080 の PNG を 3 枚ぶん吐くのが重く、窓ごとに落ち方が違った
    /// （実測 A=215 / B=199 / C=216 枚）。**書き出しが追いつく速さまで落とす**。
    static let recordingFPS = 6
    static var isRecording: Bool { ProcessInfo.processInfo.environment["DARKROOM_FRAMES"] != nil }

    @MainActor
    func windowConfig() -> SketchWindowConfig {
        SketchWindowConfig(
            width: Int(Plate.width),
            height: Int(Plate.height),
            title: "0823-darkroom — \(label)",
            fps: Self.isRecording ? Self.recordingFPS : 60,
            windowScale: 0.32,
            plugins: [syphonFactory, Witness.factory(bathID: id)]
        )
    }
}

// MARK: - 立会人

/// 槽に 1 つずつ差す**立会人**プラグイン。絵には何も足さず、次の 2 つだけを持ち帰る。
///
/// - `renderer` — `Sketch` はレンダラーを公開しない（`context` は internal）ので、
///   metaphor-syphon の互換 facade（`MetaphorRenderer.syphonOutput`）へは**プラグイン経由でしか届かない**。
///   これがあると **Syphon サーバーの実名を作品自身が読める**（`D2` / `D3` / `D4`）
/// - `posts` — この窓が最終フレームを出した回数。窓を隠しても増え続けるなら
///   `.externalRenderLoop` の promotion が効いている（`D7`）
///
/// `MetaphorOutputPlugin` ではなく**通常のプラグイン**なので、`post()` は Syphon より前に来る。
/// 見ているテクスチャは同じ（どちらも `outputTexture` = ポストエフェクト適用後）。
@MainActor
final class Witness: MetaphorPlugin {
    /// 槽ごとに 1 人。窓が別なら同じ id でも衝突しないが、読み手が分かるよう分けておく。
    static func pluginID(bathID: String) -> String { "org.darkroom.witness.\(bathID)" }

    /// 立ち会っている全員。窓を閉じると `onDetach` で自分を外す。
    private(set) static var all: [String: Witness] = [:]

    let pluginID: String
    let bathID: String

    private(set) weak var renderer: MetaphorRenderer?
    /// 最終フレームを受けた回数。
    private(set) var posts = 0
    /// 直近に受けたテクスチャの寸法（Syphon へ出るものと同じ）。
    private(set) var lastSize: (width: Int, height: Int) = (0, 0)
    /// `onDetach` が呼ばれたか（＝窓の後始末が走ったか）。
    private(set) var detached = false

    init(bathID: String) {
        self.bathID = bathID
        self.pluginID = Self.pluginID(bathID: bathID)
    }

    static func factory(bathID: String) -> PluginFactory {
        PluginFactory { Witness(bathID: bathID) }
    }

    func onAttach(renderer: MetaphorRenderer) {
        self.renderer = renderer
        detached = false
        Self.all[bathID] = self
    }

    func onDetach() {
        detached = true
        renderer = nil
    }

    func post(texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        posts += 1
        lastSize = (texture.width, texture.height)
    }

    /// この窓に立っている Syphon サーバーの実名。立っていなければ `nil`。
    ///
    /// `MetaphorRenderer.syphonOutput` は metaphor-syphon が生やしている互換 facade で、
    /// 内部の `SyphonPlugin` を id で引いて `SyphonOutput` を返す。
    var syphonServerName: String? {
        renderer?.syphonOutput?.serverName
    }

    /// Syphon サーバーが生きているか。
    var syphonActive: Bool {
        renderer?.syphonOutput?.isActive ?? false
    }
}

// MARK: - 槽の付け外し

/// 窓のポストエフェクト列を、いまの工程に合わせて入れ替える。
///
/// **毎フレーム呼ばない。** 工程が変わった瞬間だけ呼ぶ（`setPostEffects` は列を丸ごと
/// 置き換えるので、毎フレーム呼ぶと MPS のフィルタ実体が毎フレーム作り直される）。
@MainActor
enum Bathhouse {
    /// 工程 `stop` では槽を外す。3 窓が同じ絵に戻るので「3 本が別物である」ことの対照になる。
    static func apply(phase: Phase, to ctx: SketchContext, bath: Bath) {
        if phase.bathsEngaged {
            ctx.setPostEffects(bath.recipe.makeEffects())
        } else {
            ctx.clearPostEffects()
        }
    }
}

// MARK: - 3 枚を並べる当て木

/// 暗室の 3 枚を、原版 → 輪郭 → 肉付け の順に横へ並べる。
///
/// `SketchWindowConfig` にはウィンドウの位置を指定する口が無く、既定は 30px のカスケードだけ
/// （[metaphor#837](https://github.com/shinyaoguri/metaphor/issues/837) / 0816-triptych の `W7`）。
/// 3 枚が並んで初めて「同じ瞬間の・違う顔」が一目で分かる作品なので、metaphor の外へ降りて
/// AppKit で置く。**metaphor 自身の配置がどうなるかは 0816-triptych が記録済み**なので、
/// ここでは判定を取らずに素直に並べる。
///
/// `DARKROOM_ARRANGE=0` で当て木を外せば、カスケードのまま散らばった状態を見られる。
@MainActor
enum Arrangement {
    static let disabled = ProcessInfo.processInfo.environment["DARKROOM_ARRANGE"] == "0"

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
            w.setFrameOrigin(NSPoint(x: x, y: y))
            x += w.frame.width
        }
        return NSRect(x: screen.visibleFrame.midX - totalWidth / 2, y: y,
                      width: totalWidth, height: maxHeight)
    }
}
