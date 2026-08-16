import Foundation
import Metal
import metaphor

// 落ちうる口。**頼まれたときだけ踏む。**
//
// 検査に常時含めると作品が起動しなくなる（#10 の学び: v0.9.0 の
// `step(dt, iterations: -1)` を常時実行して起動不能にした）。
// `EMULSION_TRAP=<名前>` で 1 つだけ再現する。
//
//   tools/probe.sh trap mismatched-size   異サイズ入力の MergePass（metaphor#145 の回帰）
//   tools/probe.sh trap multipass-effect  多パスエフェクト + Graphics 入力（既知の崩れ）
//   tools/probe.sh trap shared-node       同じノードを両入力に入れる（メモ化の確認）
//   tools/probe.sh trap list              名前の一覧
//
// **仕掛けたら必ず数フレーム回してから読み戻す。** 最初これを `setup()` の中で
// 組んだ直後に `exit(0)` していて、3 つとも「組めた」しか言わずに終わっていた。
// `MergePass` も `EffectPass` もレンダラーがフレームを回して初めて実行されるので、
// 組めたことは何の証拠にもならない。

@MainActor
final class Trap {
    let name: String
    /// 読み戻して判定する対象。グラフのルート。
    private let root: RenderPassNode?
    /// 読み取り点と、その点に何が出ていれば正常かの説明。
    private let probePoint: (x: Int, y: Int)
    private let expectation: String

    private init(name: String, root: RenderPassNode?, probePoint: (x: Int, y: Int), expectation: String) {
        self.name = name
        self.root = root
        self.probePoint = probePoint
        self.expectation = expectation
    }

    static let names = ["mismatched-size", "multipass-effect", "multipass-merged", "shared-node"]

    /// 仕掛ける。戻り値が nil なら、この後に回すものは無い。
    static func arm(_ name: String, sketch: Sketch0816Emulsion) -> Trap? {
        switch name {

        // metaphor#145（CLOSED）— MergePass が異サイズ入力で境界外 read をしていた。
        // 直っていれば出力は大きい方に合わせ、**小さい方が届かない領域は透明黒**として
        // 扱われる（シェーダが範囲外 read を明示的に避けている）。
        // つまり 256 の青地の外周部は、64 の赤が足されず青のままになるはず。
        case "mismatched-size":
            guard let small = sketch.createGraphics(64, 64),
                  let big = sketch.createGraphics(256, 256) else {
                Emulsion.say("[trap] createGraphics が nil"); return nil
            }
            bake(small, r: 255, g: 0, b: 0)
            bake(big, r: 0, g: 0, b: 255)
            let ns = PlateNode(label: "small64", graphics: small)
            let nb = PlateNode(label: "big256", graphics: big)
            Emulsion.say("[trap] MergePass(big256=青, small64=赤, .add) を組む")
            guard let m = sketch.createMergePass(nb, ns, blend: .add) else {
                Emulsion.say("[trap] createMergePass が nil"); return nil
            }
            sketch.setRenderGraph(RenderGraph(root: m))
            return Trap(name: name, root: m, probePoint: (200, 200),
                expectation: "出力 256x256 の (200,200) は 64 の外側なので、赤が足されず"
                    + " (0.000, 0.000, 1.000) のままなら境界外 read は起きていない")

        // 公式サンプル（Examples/Samples/RenderGraphCompose）のコメントが明言する既知の穴:
        //   「Bloom や大半径 Blur など複数の中間ヒープテクスチャを使う多パスエフェクトは
        //     EffectPass 経由 + Graphics 入力で描画が崩れる」
        case "multipass-effect":
            guard let g = sketch.createGraphics(512, 512) else {
                Emulsion.say("[trap] createGraphics が nil"); return nil
            }
            g.beginDraw()
            g.background(0, 0, 0, 255)
            g.noStroke()
            g.fill(255, 240, 120)
            g.circle(256, 256, 120)
            g.endDraw(wait: true)
            let node = PlateNode(label: "bright", graphics: g)
            Emulsion.say("[trap] EffectPass(Graphics 入力, [BloomEffect]) を組む")
            guard let fx = sketch.createEffectPass(node, effects: [BloomEffect(intensity: 1.4, threshold: 0.5)]) else {
                Emulsion.say("[trap] createEffectPass が nil"); return nil
            }
            sketch.setRenderGraph(RenderGraph(root: fx))
            return Trap(name: name, root: fx, probePoint: (256, 256),
                expectation: "円の中心 (256,256) が明るい黄（r,g が高く b が低い）なら通っている。"
                    + "真っ黒・真っ白・別物なら既知の崩れが残っている")

        // `multipass-effect` が素通りしたので、**公式サンプルにより近い形**でもう一度踏む。
        // あちらは EffectPass 単体をルートにするのではなく、**マージの片脚**に置いていた。
        // 崩れが「多パスエフェクト単体」ではなく「マージと組み合わせたとき」に出るなら、
        // 変えるべきはここ 1 か所。
        case "multipass-merged":
            guard let bg = sketch.createGraphics(512, 512),
                  let fg = sketch.createGraphics(512, 512) else {
                Emulsion.say("[trap] createGraphics が nil"); return nil
            }
            bake(bg, r: 20, g: 28, b: 50)
            fg.beginDraw()
            fg.background(0, 0, 0, 255)
            fg.noStroke()
            fg.fill(255, 240, 120)
            fg.circle(256, 256, 120)
            fg.endDraw(wait: true)
            let bgNode = PlateNode(label: "bg", graphics: bg)
            let fgNode = PlateNode(label: "fg", graphics: fg)
            Emulsion.say("[trap] MergePass(bg, EffectPass(fg, [BloomEffect]), .add) を組む")
            guard let fx2 = sketch.createEffectPass(fgNode, effects: [BloomEffect(intensity: 1.4, threshold: 0.5)]),
                  let merged = sketch.createMergePass(bgNode, fx2, blend: .add) else {
                Emulsion.say("[trap] createEffectPass / createMergePass が nil"); return nil
            }
            sketch.setRenderGraph(RenderGraph(root: merged))
            return Trap(name: name, root: merged, probePoint: (256, 256),
                expectation: "円の中心は 背景(0.078,0.110,0.196) + ブルームした黄 なので"
                    + " r,g が高く b が中程度。真っ黒・真っ白・帯状なら崩れている")

        // RenderGraph は DAG を名乗るが、同じノードを 2 度通る形を弾く口は無い。
        // `MergePass` は frameToken でメモ化していると doc に書かれている
        // （metaphor#145 が「メモ化要件が未文書」と指摘していた箇所）。
        // 同じノードを両入力に入れて、二重実行が事故らないかを見る。
        case "shared-node":
            guard let g = sketch.createGraphics(128, 128) else {
                Emulsion.say("[trap] createGraphics が nil"); return nil
            }
            bake(g, r: 0, g: 128, b: 0)
            let node = PlateNode(label: "leaf", graphics: g)
            guard let m1 = sketch.createMergePass(node, node, blend: .add) else {
                Emulsion.say("[trap] createMergePass が nil"); return nil
            }
            Emulsion.say("[trap] MergePass(node, node, .add) — 同じノードを両入力に入れた")
            sketch.setRenderGraph(RenderGraph(root: m1))
            return Trap(name: name, root: m1, probePoint: (64, 64),
                expectation: "0.502 の緑を自分自身に足すので (0.000, 1.004→1.000, 0.000)。"
                    + "緑が 0.502 のままなら片方しか読まれていない")

        case "list":
            Emulsion.say("trap: \(names.joined(separator: " / "))")
            return nil

        default:
            Emulsion.say("[trap] 未知の名前: \(name)（\(names.joined(separator: " / "))）")
            return nil
        }
    }

    /// 数フレーム回した後に呼ぶ。読み戻して判定を出す。
    func report() {
        guard let tex = root?.output else {
            Emulsion.say("[trap] \(name): ルートの output が nil のまま（グラフが実行されていない）")
            return
        }
        let img = MImage(texture: tex)
        img.loadPixels()
        guard !img.pixels.isEmpty else {
            Emulsion.say("[trap] \(name): 出力を読み戻せなかった")
            return
        }
        let c = img.get(probePoint.x, probePoint.y)
        Emulsion.say("[trap] \(name): 出力 \(tex.width)x\(tex.height) の "
            + "(\(probePoint.x),\(probePoint.y)) = \(Hue.s((c.r, c.g, c.b, c.a)))")
        Emulsion.say("[trap] 判定の目安: \(expectation)")
    }

    /// 単色で焼く。`L8` のとおり `background` は α<1 だと 1 フレーム遅れるので、
    /// 不透明色でも矩形を 1 枚重ねて確実に届かせる。
    private static func bake(_ g: Graphics, r: Float, g gg: Float, b: Float) {
        g.beginDraw()
        g.background(r, gg, b, 255)
        g.noStroke()
        g.fill(r, gg, b, 255)
        g.rect(0, 0, g.width, g.height)
        g.endDraw(wait: true)
    }
}
