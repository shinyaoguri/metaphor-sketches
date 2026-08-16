import Metal
import metaphor

// 合成の配線。焼いた層を `RenderGraph` に載せて 1 枚にする。
//
// ─── ここで分かったこと（配線を書く前に読むと早い）─────────────────────────
//
// 1. **`SourcePass` はスケッチの言葉で描けない。** `onDraw` が渡してくるのは
//    生の `MTLRenderCommandEncoder` で、`circle()` も `sphere()` も無い。
//    Metal を手で書かない限り絵は入らない。metaphor 同梱の公式サンプル
//    （`Examples/Samples/RenderGraphCompose`）が `SourcePass` を使わず
//    `Graphics` を包むアダプタを自作しているのはこのため。ここでも同じ形を採る。
//
// 2. **`Graphics3D` も同じ手で包める。** `texture` が公開されているので、
//    2D の層と 3D の層を**同じ種類のノードとして**グラフに載せられる。
//    「2D と 3D が混在する」がグラフの言葉ではただの 2 ノードになる。
//
// 3. **グラフを立てるとメインキャンバスの描画は画面に出ない。**
//    最終出力がグラフのルートテクスチャに差し替わるため。文字も別の層に焼いて
//    グラフへ載せるしかない（`Layers.hud`）。

// MARK: - Graphics → RenderPassNode

/// 2D オフスクリーンをグラフのノードに見せる薄いラッパー。
///
/// 描画は `Graphics` 側の `beginDraw()`〜`endDraw()` で既に済んでおり、
/// 同一コマンドキューの commit 順序で後段から正しく読まれる。だから
/// `execute` は何もしない。
@MainActor
final class PlateNode: RenderPassNode {
    let label: String
    let graphics: Graphics
    var output: MTLTexture? { graphics.texture }

    init(label: String, graphics: Graphics) {
        self.label = label
        self.graphics = graphics
    }

    func execute(commandBuffer: MTLCommandBuffer, time: Double, renderer: MetaphorRenderer) {}
}

/// 3D オフスクリーンをグラフのノードに見せる薄いラッパー。`PlateNode` の 3D 版。
@MainActor
final class SubjectNode: RenderPassNode {
    let label: String
    let graphics: Graphics3D
    var output: MTLTexture? { graphics.texture }

    init(label: String, graphics: Graphics3D) {
        self.label = label
        self.graphics = graphics
    }

    func execute(commandBuffer: MTLCommandBuffer, time: Double, renderer: MetaphorRenderer) {}
}

// MARK: - 焼き付けの配線

/// 2 通りの焼き方（場面 2 と場面 3）を組み立てて保持する。
///
/// 場面ごとにグラフを組み直すのではなく、**先に両方組んでおいて差し替える**。
/// ノードを作り直すとテクスチャも作り直しになり、場面が変わるたびに
/// GPU メモリが増減してソークの読みが濁る。
@MainActor
final class Darkroom0 {
    // 層のノード
    let plateNode: PlateNode
    let subjectNode: SubjectNode
    let hudNode: PlateNode

    // 場面 2 — 重ね焼き。`blend` を実行時に差し替えて 4 通りを巡る
    let superimpose: MergePass
    let superimposeRoot: MergePass
    let superimposeGraph: RenderGraph

    // 場面 3 — 分岐。版を 2 経路へ分け、片方だけ反転する
    let negPlate: EffectPass
    let ghost: MergePass
    let branch: MergePass
    let branchRoot: MergePass
    let branchGraph: RenderGraph

    init?(sketch: Sketch0816Emulsion, layers: Layers) {
        plateNode = PlateNode(label: "plate", graphics: layers.plate)
        subjectNode = SubjectNode(label: "subject", graphics: layers.subject)
        hudNode = PlateNode(label: "hud", graphics: layers.hud)

        // ── 場面 2 ────────────────────────────────────────────────
        //   plate ──┐
        //           ├─ MergePass(可変) ──┐
        //   subject ┘                    ├─ MergePass(.alpha) ── 画面
        //   hud ─────────────────────────┘
        guard let sup = sketch.createMergePass(plateNode, subjectNode, blend: .screen),
              let supRoot = sketch.createMergePass(sup, hudNode, blend: .alpha)
        else { return nil }
        superimpose = sup
        superimposeRoot = supRoot
        superimposeGraph = RenderGraph(root: supRoot)

        // ── 場面 3 ────────────────────────────────────────────────
        //   plate ──┬───────────────────────┐
        //           └─ EffectPass(Invert) ──┤
        //                                   ├─ MergePass(.multiply) = 版 × 版のネガ
        //                                   │        │
        //   subject ──────────────────────────────── MergePass(.alpha)
        //   hud ─────────────────────────────────────────── MergePass(.alpha) ── 画面
        //
        // **plate が 2 本の経路へ分かれている**のがこの場面の主題。
        // 素の版と反転した版を掛け合わせると中間調だけが残り、暗室らしい絵になる。
        // 同時に「エフェクトが片方の経路にだけ効くか」（`G3`）の検査台にもなる。
        //
        // 被写体を載せるのに `.alpha` ではなく `.screen` を使っているのは
        // 好みではなく**検査で分かった制約**による。`Graphics3D` には
        // `background()` が無く、下地は不透明の黒で固定される（判定 `L3`）。
        // 不透明な層を `.alpha` の前景に置くと、下の層が問答無用で消える。
        // 黒が効かない `.screen` なら、被写体の形だけが版の上に乗る。
        // （`.alpha` で何が起きるかは場面 2 が毎巡そのまま見せている）
        guard let neg = sketch.createEffectPass(plateNode, effects: [InvertEffect()]),
              let gh = sketch.createMergePass(plateNode, neg, blend: .multiply),
              let br = sketch.createMergePass(gh, subjectNode, blend: .screen),
              let brRoot = sketch.createMergePass(br, hudNode, blend: .alpha)
        else { return nil }
        negPlate = neg
        ghost = gh
        branch = br
        branchRoot = brRoot
        branchGraph = RenderGraph(root: brRoot)
    }
}
