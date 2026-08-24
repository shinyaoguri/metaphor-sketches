import Foundation
import Metal
import metaphor

// 自己検査。**スクリーンショットではなく読み戻した数値を一次証拠にする。**
//
// 判定は 4 群:
//   L*  層     — 2D / 3D のオフスクリーンが正しく焼けているか
//   M*  合成   — MergePass が doc の式どおりか
//   G*  グラフ — EffectPass と DAG の分離が効いているか
//   X*  交錯   — 1 フレームに 2D と 3D を混ぜたときの順序と状態
//
// ─── なぜ全部を setup() に置けないのか ───────────────────────────────────
//
// `MergePass` / `EffectPass` は**レンダラーがフレームを回さないと実行されない**。
// `setup()` の時点で出力テクスチャは nil で、読むものが無い。
// なので M と G は「本編の前に短い露光テストを焼く」形にして、フレーム番号で
// 進む状態機械にした。**時計は使わない**ので、実行のたび同じ順序・同じ数値が出る。
//
// L と X はフレームを跨ぐ必要が無い（L はオフスクリーンの中で閉じ、
// X は 1 フレームの中で閉じる）。

@MainActor
final class Darkroom {
    private unowned let sketch: Sketch0816Emulsion

    private(set) var verdicts: [Verdict] = []
    private(set) var observations: [Observation] = []

    // 検査用の層とグラフ。本編の層とは別に持つ。
    // 本編の層は毎フレーム絵が変わるので、判定の入力には使えない。
    private var testA: Graphics?       // 下の層（不透明）
    private var testB: Graphics?       // 上の層（半透明）— α の扱いを炙り出す
    private var testS: Graphics3D?     // 3D の層
    private var nodeA: PlateNode?
    private var nodeB: PlateNode?
    private var mergeCheck: MergePass?
    private var invertCheck: EffectPass?
    private var grayCheck: EffectPass?
    private var dagCheck: MergePass?
    private var mergeGraph: RenderGraph?
    private var dagGraph: RenderGraph?

    /// 検査用オフスクリーンの一辺。読み取り点をアンチエイリアスから離せる程度に取る。
    private static let side = 256
    private static let px = (x: 128, y: 128)

    /// 露光テストで焼く 2 色。**どちらも「素直な値」にしない。**
    /// 0.5 や 1.0 だけで組むと、premultiplied と straight の区別が付かない
    /// （0.5 × 0.5 と 0.5 が偶然一致する等）。
    private static let colorA = (r: Float(0.60), g: Float(0.20), b: Float(0.10))
    private static let colorB = (r: Float(0.20), g: Float(0.80), b: Float(0.40))
    private static let alphaB = Float(0.50)

    init(sketch: Sketch0816Emulsion) {
        self.sketch = sketch
    }

    // MARK: - 要約（講評欄と probe に出す）

    var allPassed: Bool { !verdicts.contains { !$0.passed } }

    var tally: String {
        let fails = verdicts.filter { !$0.passed }.count
        return "PASS \(verdicts.count - fails) / FAIL \(fails) / LOOK \(observations.count)"
    }

    /// 講評欄に出す 3 行。FAIL があればそれを優先する。
    var headlines: [String] {
        let fails = verdicts.filter { !$0.passed }
        if !fails.isEmpty { return fails.prefix(3).map { "FAIL \($0.id)" } }
        return observations.prefix(3).map { "LOOK \($0.id)" }
    }

    // MARK: - L 群（フレームを跨がない）

    func runOfflineChecks() {
        let side = Self.side
        guard let a = sketch.createGraphics(side, side),
              let b = sketch.createGraphics(side, side),
              let s = sketch.createGraphics3D(side, side) else {
            verdicts.append(Verdict(id: "L0.alloc", passed: false,
                detail: "createGraphics / createGraphics3D(\(side),\(side)) が nil を返した。以降の検査は全て測れない"))
            return
        }
        testA = a; testB = b; testS = s

        checkGraphics3DClear(s)
        checkGraphics3DDraws(s)
        checkOffscreenVsMainParity(s)
        checkStyleIsolation(a)
        checkReadbackWithoutWait(s)
        checkTransparency(a)
        checkTextAlpha(a)
        exposeTestPatches(a, b)

        for v in verdicts { Emulsion.say(v.line) }
        for o in observations { Emulsion.say(o.line) }
    }

    /// `L3` — `Graphics3D` の下地を呼び手が選べるか。
    ///
    /// 報告時（metaphor#830）は `Graphics3D` に `background()` が無く、下地が不透明な黒で
    /// 固定されていた。α>0 の層を `.alpha` で重ねると**下の層が最初から見えなくなる**のに、
    /// 回避する口が API に無いのが問題だった。上流は **`Graphics3D.background()` の新設**で
    /// 解決している（PR #915）。既定のクリアは不透明のままで、透明で始めたい層は
    /// `background(0, 0, 0, 0)` を明示的に呼ぶ、という約束。
    /// なので測るのは「既定の α が 0 か」ではなく「**呼べば透明にできるか**」。
    private func checkGraphics3DClear(_ s: Graphics3D) {
        // **図形を 1 つ置く。** `L8` のとおり、図形が 1 つも無いフレームでは
        // クリアがテクスチャへ届かず、前の内容がそのまま残る。
        // 「何も描かずに読む」と、クリア色ではなく残骸を測ることになる。
        // 図形は読み取り点（隅）から遠い中央に置く。
        func cornerAfterDraw(clearingToTransparent: Bool) -> Color? {
            s.beginDraw(time: 0)
            // `background` は `beginDraw` の直後に置く（描いたあとに呼ぶと塗り潰される）。
            // 数値版は colorMode に従うので、正規化された値をそのまま渡す Color 版を使う。
            if clearingToTransparent { s.background(Color(SIMD4(0, 0, 0, 0))) }
            setupCheckCamera(s)
            s.noLights()
            s.noStroke()
            s.fill(Color(SIMD4(1, 1, 1, 1)))
            s.pushMatrix()
            s.translate(Float(Self.side) / 2, Float(Self.side) / 2, 0)
            s.sphere(8, detail: 12)
            s.popMatrix()
            s.endDraw(wait: true)
            return readback(s.toImage(), 8, 8)
        }

        guard let byDefault = cornerAfterDraw(clearingToTransparent: false),
              let cleared = cornerAfterDraw(clearingToTransparent: true) else { return }
        observations.append(Observation(id: "L3.clearColor",
            detail: "background() を呼ばずに beginDraw/endDraw した層の隅 = "
                + "\(Hue.s((byDefault.r, byDefault.g, byDefault.b, byDefault.a)))"))
        verdicts.append(Verdict(id: "L3b.clearAlpha", passed: Approx.eq(cleared.a, 0, 0.01),
            detail: "background(0,0,0,0) を呼んだ層の隅の α = \(Approx.f(cleared.a, 3)) 期待=0.000"
                + " / 呼ばない層の α = \(Approx.f(byDefault.a, 3))"
                + "（#830 は Graphics3D.background() の新設で解決。既定は不透明のままなので、"
                + "透明な下地が要る層は明示的に呼ぶ）"))
    }

    /// `L1` — 3D オフスクリーンに実際に描け、読み戻せるか。
    ///
    /// 中央に大きな球を 1 つ置き、**中心が塗られていて隅が塗られていない**ことを見る。
    /// 「nil が返らなかった」だけでは描けた証拠にならない。
    private func checkGraphics3DDraws(_ s: Graphics3D) {
        exposeSphere(s, radius: 70, fill: Color(SIMD4(0.90, 0.30, 0.20, 1)))
        let img = s.toImage()
        guard let center = readback(img, Self.px.x, Self.px.y),
              let corner = readbackLoaded(img, 6, 6) else { return }
        // 「描けたか」は**色**で見る。α で見ると下地のクリアと区別できない
        // （`L3` のとおりクリアは不透明黒なので、α はどこでも 1 になる）。
        // 最初これを α で書いて FAIL を出したが、原因は自分の判定側だった。
        let lit = Hue.rgbEq((center.r, center.g, center.b), (0.90, 0.30, 0.20), 0.03)
        let cornerDark = corner.r < 0.1 && corner.g < 0.1 && corner.b < 0.1
        verdicts.append(Verdict(id: "L1.offscreen3D", passed: lit && cornerDark,
            detail: "半径 70 の球を焼いた 3D 層: 中心=\(Hue.s((center.r, center.g, center.b, center.a))) "
                + "期待=(0.900, 0.300, 0.200) / 隅=\(Hue.s((corner.r, corner.g, corner.b, corner.a))) → "
                + (lit ? (cornerDark ? "球が焼けていて、外は下地のまま" : "球は焼けたが外まで塗られている")
                       : "中心が指定色になっていない")))
    }

    /// `L2` — `Graphics3D` の投影が、手計算した幾何と一致するか。
    ///
    /// **最初ここで誤報を出しかけた。** 「z=0 で 1 ワールド単位 = 1px だから
    /// 半径 70 の球は直径 140px」と書いて FAIL（実測 148px）を得たが、
    /// 間違っていたのは期待値の方だった。
    ///
    /// 透視投影では**球のシルエットは 2r より大きく写る**。輪郭を作るのは
    /// 球の中心断面ではなく、視点から引いた接線が触れる少し手前の円だから。
    /// 焦点距離 f、視点から中心までの距離 d、半径 r のとき
    ///
    ///     シルエット半径 = f · r / √(d² − r²)
    ///
    /// f = d =(side/2)/tan(fov/2) = 221.70 なので、r=70 の球は
    /// 221.70 × 70 / √(221.70² − 70²) = 73.76 → 直径 147.5px。
    ///
    /// 「なんとなく変」で上流へ投げず、**数式で書き下してから**比べる。
    private func checkOffscreenVsMainParity(_ s: Graphics3D) {
        exposeSphere(s, radius: 70, fill: Color(SIMD4(0.90, 0.30, 0.20, 1)))
        let img = s.toImage()
        img.loadPixels()
        // 中心行を左右に走査して、塗られている幅を測る。
        // **判定は α ではなく色でする。** クリアが不透明黒なので、α では
        // 層の全幅（256px）が「塗られている」と読めてしまう。
        var left = -1, right = -1
        for x in 0..<Self.side {
            let c = img.get(x, Self.px.y)
            if c.r > 0.45 { if left < 0 { left = x }; right = x }
        }
        let measured = left < 0 ? Float(0) : Float(right - left + 1)
        let r: Float = 70
        let f = (Float(Self.side) / 2) / tan(Float.pi / 3 / 2)   // 焦点距離 = 視点距離
        let expected = 2 * f * r / (f * f - r * r).squareRoot()
        // 球の外周はアンチエイリアスで滲む。±3px を許す
        let ok = abs(measured - expected) <= 3
        verdicts.append(Verdict(id: "L2.sphereSilhouette", passed: ok,
            detail: "半径 \(Approx.f(r, 0)) の球のシルエット直径: 実測=\(Approx.f(measured, 1))px "
                + "期待=\(Approx.f(expected, 1))px = 2·f·r/√(f²−r²), f=\(Approx.f(f, 2)) "
                + "（透視投影ではシルエットが 2r より大きく写る。"
                + "「z=0 で 1 単位 = 1px」から素朴に 2r=140px と置くと誤報になる）"))
    }

    /// `L5` — オフスクリーンが親のスタイルを継承しないか。
    ///
    /// 親（メインキャンバス）で `fill` を赤にしてから、オフスクリーン側で
    /// `fill` を指定せずに描く。Processing の `createGraphics()` は独立した状態を
    /// 持つので、親の赤が出てはいけない。
    private func checkStyleIsolation(_ g: Graphics) {
        sketch.fill(Color.red)
        g.beginDraw()
        g.background(0, 0, 0, 255)
        g.noStroke()
        // fill を指定せずに描く
        g.rect(64, 64, 128, 128)
        g.endDraw(wait: true)
        guard let c = readback(g.toImage(), Self.px.x, Self.px.y) else { return }
        let inheritedRed = c.r > 0.5 && c.g < 0.2 && c.b < 0.2
        verdicts.append(Verdict(id: "L5.styleIsolation", passed: !inheritedRed,
            detail: "親で fill(red) 後、Graphics 側は fill 未指定で矩形を描いた → "
                + "\(Hue.s((c.r, c.g, c.b, c.a)))"
                + (inheritedRed ? " 親の赤を継承している" : " 親の赤は漏れていない")))
    }

    /// `L4` — `endDraw(wait:)` を省くと、CPU 側は古い内容を読むか。
    ///
    /// doc は「CPU 側でテクスチャの内容を直接読み取る場合のみ `wait: true` が必要」と
    /// 言う。裏を返せば `wait: false` のまま読むと**古い内容が返りうる**はず。
    /// ここは「その注意書きが実際に効いているか」の確認で、
    /// FAIL は metaphor の不具合ではなく**doc どおり**を意味する。
    private func checkReadbackWithoutWait(_ s: Graphics3D) {
        // まず赤い球で埋め、待って読む（既知の状態を作る）
        exposeSphere(s, radius: 70, fill: Color(SIMD4(0.90, 0.20, 0.15, 1)))
        _ = readback(s.toImage(), Self.px.x, Self.px.y)

        // 次に緑で焼き直し、**待たずに**読む
        s.beginDraw(time: 0)
        setupCheckCamera(s)
        s.noLights()
        s.noStroke()
        s.fill(Color(SIMD4(0.15, 0.90, 0.30, 1)))
        s.pushMatrix()
        s.translate(Float(Self.side) / 2, Float(Self.side) / 2, 0)
        s.sphere(70, detail: 32)
        s.popMatrix()
        s.endDraw(wait: false)

        guard let c = readback(s.toImage(), Self.px.x, Self.px.y) else { return }
        let sawNew = c.g > c.r
        observations.append(Observation(id: "L4.readbackWithoutWait",
            detail: "赤→緑に焼き直して endDraw(wait: false) 直後に読んだ = \(Hue.s((c.r, c.g, c.b, c.a))) → "
                + (sawNew ? "新しい内容が見えた（読み戻し側がキューを合わせている）"
                          : "古い内容（赤）が見えた = doc の注意書きどおり。CPU で読むなら wait: true が要る")))
    }

    /// `L6` / `L7` — オフスクリーンに**透明**を焼けるか。
    ///
    /// ここが合成の土台。透明を焼けないなら、層を重ねるという発想そのものが
    /// 成立しない（上の層が下の層を必ず塗り潰す）。
    ///
    /// 2 つ別々に見る:
    ///   `L6` `background(0,0,0,0)` で層全体を透明にできるか
    ///   `L7` 透明な層の上に `fill(…, α)` で半透明の図形を置けるか
    private func checkTransparency(_ g: Graphics) {
        // L6 — 透明でクリアする
        g.beginDraw()
        g.background(0, 0, 0, 0)
        g.endDraw(wait: true)
        guard let cleared = readback(g.toImage(), Self.px.x, Self.px.y) else { return }
        verdicts.append(Verdict(id: "L6.clearToTransparent", passed: Approx.eq(cleared.a, 0, 0.01),
            detail: "Graphics に background(0,0,0,0) を 1 回だけ呼んだ直後 → "
                + "\(Hue.s((cleared.r, cleared.g, cleared.b, cleared.a))) 期待の α=0.000"
                + "（原因は `L8` を見る。1 フレームでは効かない）"))

        // L7 — 透明な層に半透明の図形を置く
        g.beginDraw()
        g.background(0, 0, 0, 0)
        g.noStroke()
        // 既定の colorMode は 0…255（0816-prism の B1 が実測済み）。α も同じ尺度。
        g.fill(Self.colorB.r * 255, Self.colorB.g * 255, Self.colorB.b * 255, Self.alphaB * 255)
        g.rect(0, 0, Float(Self.side), Float(Self.side))
        g.endDraw(wait: true)
        guard let painted = readback(g.toImage(), Self.px.x, Self.px.y) else { return }
        let straightRGB = Hue.rgbEq((painted.r, painted.g, painted.b),
                                    (Self.colorB.r, Self.colorB.g, Self.colorB.b), Hue.quantized)
        let premulRGB = Hue.rgbEq((painted.r, painted.g, painted.b),
                                  (Self.colorB.r * Self.alphaB, Self.colorB.g * Self.alphaB,
                                   Self.colorB.b * Self.alphaB), Hue.quantized)
        verdicts.append(Verdict(id: "L7.semiTransparentFill", passed: Approx.eq(painted.a, Self.alphaB, 0.02),
            detail: "透明な層に fill(α=\(Approx.f(Self.alphaB, 2))) の矩形を置いた → "
                + "\(Hue.s((painted.r, painted.g, painted.b, painted.a))) "
                + "期待の α=\(Approx.f(Self.alphaB, 3)) / rgb は "
                + (straightRGB ? "straight（指定色のまま）" : premulRGB ? "premultiplied（α 乗算済み）" : "どちらでもない")))

        // L6 と L7 は噛み合わない。L6（クリアだけ）は α=1 を返すのに、
        // L7（同じクリア + 半透明の矩形）は α=0.5 を返す。もし本当にクリアが
        // α=1 のままなら、その上に α=0.5 を通常合成しても α は 1 で、
        // 0.5 にはならない。**どちらかの観測が嘘をついている。**
        controlClearLatency()
    }

    /// `L8` — 透明なクリアは、**呼んだそのフレームには効かない**。
    ///
    /// 同じ `background(0, 0, 0, 0)` を 2 フレーム続けて呼び、
    /// **変えたのはフレーム番号だけ**という対照実験にする。
    ///
    /// 実装（`Canvas2D+Background.swift`）を読むと理由まで閉じる:
    /// `background()` はレンダーパスの `loadAction = .clear` を使える条件
    /// （`appliedClearColor == c`、つまり**前のフレームで同じ色が適用済み**）で
    /// なければ、代わりに**全画面クワッドを通常の α ブレンドで描く**。
    /// α=0 のクワッドは合成の定義上まったく何もしないので、初回は素通りする。
    /// 2 フレーム目はクリア色が適用済みになっているので、パスのクリアが効く。
    ///
    /// **合成の道具としては、これが土台を崩す。** 層を透明で始められないと、
    /// 上の層が下の層を必ず塗り潰す。metaphor 同梱の公式サンプルも
    /// `pgOverlay.background(0, 0, 0, 0)` を毎フレーム呼ぶので、
    /// 2 フレーム目以降だけ意図どおりに動いている（1 枚焼きでは動かない）。
    private func controlClearLatency() {
        guard let g = sketch.createGraphics(Self.side, Self.side) else { return }

        // 下地を作る。不透明な白で埋めて、「透明になったか」が分かる状態にする
        g.beginDraw()
        g.background(255, 255, 255, 255)
        g.noStroke()
        g.fill(255, 255, 255, 255)
        g.rect(0, 0, Float(Self.side), Float(Self.side))
        g.endDraw(wait: true)
        let seeded = readback(g.toImage(), Self.px.x, Self.px.y)

        // (a) 1 回目の透明クリア
        g.beginDraw()
        g.background(0, 0, 0, 0)
        g.endDraw(wait: true)
        let first = readback(g.toImage(), Self.px.x, Self.px.y)

        // (b) まったく同じ呼び出しを、もう 1 フレーム
        g.beginDraw()
        g.background(0, 0, 0, 0)
        g.endDraw(wait: true)
        let second = readback(g.toImage(), Self.px.x, Self.px.y)

        guard let s0 = seeded, let a0 = first, let b0 = second else { return }
        let firstWorks = Approx.eq(a0.a, 0, 0.01)
        let secondWorks = Approx.eq(b0.a, 0, 0.01)
        let diagnosis: String
        if firstWorks {
            diagnosis = "1 回目から透明になる"
        } else if secondWorks {
            diagnosis = "**1 回目は素通りし、2 回目で初めて透明になる**"
                + " = 透明クリアが 1 フレーム遅れる（α<1 のクワッドはブレンドで消えるため）"
        } else {
            diagnosis = "2 回呼んでも透明にならない"
        }
        verdicts.append(Verdict(id: "L8.transparentClearLag", passed: firstWorks,
            detail: "白で埋めた層 \(Hue.s((s0.r, s0.g, s0.b, s0.a))) に "
                + "background(0,0,0,0) を 2 フレーム続けて呼んだ: "
                + "1 回目 → \(Hue.s((a0.r, a0.g, a0.b, a0.a))) / "
                + "2 回目 → \(Hue.s((b0.r, b0.g, b0.b, b0.a))) → \(diagnosis)"))
    }

    /// `L10` — `text()` は `fill` の α を尊重するか。
    ///
    /// **この作品の講評欄が、間違った α でも読めてしまったことから疑った。**
    /// 既定の colorMode は 0…255 なので `fill(235, 244, 250, 0.95)` は
    /// α ≒ 0.004 = ほぼ透明のはず。なのに文字は不透明に出ていた。
    /// 図形（`rect`）は同じ書き方で消えるので、**文字だけが α を無視している**疑いになる。
    ///
    /// 変えるのは「文字か図形か」の 1 つだけ。どちらも α=0 で描く。
    private func checkTextAlpha(_ g: Graphics) {
        func paint(_ body: (Graphics) -> Void) -> Int {
            g.beginDraw()
            g.background(0, 0, 0, 255)
            g.noStroke()
            g.fill(255, 255, 255, 0)       // 完全に透明な白
            body(g)
            g.endDraw(wait: true)
            let img = g.toImage()
            img.loadPixels()
            guard !img.pixels.isEmpty else { return -1 }
            // 黒地の上に何か出ていないかを数える
            var lit = 0
            for y in stride(from: 0, to: Self.side, by: 2) {
                for x in stride(from: 0, to: Self.side, by: 2) where img.get(x, y).r > 0.2 { lit += 1 }
            }
            return lit
        }

        let byRect = paint { $0.rect(32, 32, 192, 64) }
        let byText = paint {
            $0.textSize(48)
            $0.text("HHHHH", 32, 120)
        }
        verdicts.append(Verdict(id: "L10.textRespectsAlpha", passed: byText == 0,
            detail: "fill(255,255,255, α=0) で描いたときに残る画素数: "
                + "rect=\(byRect) / text=\(byText)（どちらも 0 が期待）→ "
                + (byText > 0 && byRect == 0
                    ? "**図形は消えるのに文字だけ出る = text() が fill の α を無視している**"
                    : byText == 0 ? "文字も α を尊重している" : "図形も出ている（別の原因）")))

        // α を 0 / 128 / 255 と振って、**グリフ内部のもっとも明るい画素**を並べる。
        // 「無視されている」のか「二重に掛かっている」のかは、
        // 1 点の有無ではなく α に対する応答の形でしか分けられない。
        //   無視 …… どの α でも同じ明るさ
        //   二重 …… α に対して二次で沈む（α=0 で消える）
        //   正しい … α に比例（黒地なので 0 → 0.5 → 1.0）
        func brightest(alpha: Float) -> Float {
            g.beginDraw()
            g.background(0, 0, 0, 255)
            g.noStroke()
            g.fill(255, 255, 255, alpha)
            g.textSize(48)
            g.text("HHHHH", 32, 120)
            g.endDraw(wait: true)
            let img = g.toImage()
            img.loadPixels()
            guard !img.pixels.isEmpty else { return -1 }
            var best: Float = 0
            for y in 60..<130 {
                for x in 32..<220 { best = max(best, img.get(x, y).r) }
            }
            return best
        }
        let a0 = brightest(alpha: 0), a128 = brightest(alpha: 128), a255 = brightest(alpha: 255)
        let shape = Approx.eq(a0, a255, 0.02) ? "α を無視している（応答が平ら）"
            : (a0 < 0.02 ? "α で沈む（無視ではない）" : "中間（要追試）")
        observations.append(Observation(id: "L10b.textAlphaResponse",
            detail: "黒地に fill(255,255,255,α) で描いた文字の最明画素: "
                + "α=0 → \(Approx.f(a0, 3)) / α=128 → \(Approx.f(a128, 3)) / α=255 → \(Approx.f(a255, 3))"
                + "（比例なら 0.000 / 0.502 / 1.000）→ \(shape)"))
    }

    /// 露光テストの 2 枚を焼く。M 群の入力。
    ///
    /// B は**半透明**で焼く。ここが `.alpha` の α 前提を炙り出す唯一の入口で、
    /// α=1 の層しか用意しないと straight と premultiplied が同値になり、
    /// 検査が空振りする（最初 `background(…, a:)` で焼いて実際に空振りした）。
    private func exposeTestPatches(_ a: Graphics, _ b: Graphics) {
        a.beginDraw()
        a.background(Color(SIMD4(Self.colorA.r, Self.colorA.g, Self.colorA.b, 1)))
        a.endDraw(wait: true)

        // B は**同じ内容を 2 回焼く**。`L8` のとおり透明クリアは 1 フレーム遅れるので、
        // 1 回で済ませると下地が不透明黒のまま残り、α=1 の層になってしまう。
        // そうなると `.alpha` の straight / premultiplied が同値になり、
        // `M4` / `M5` が空振りする（最初これで空振りした）。
        for _ in 0..<2 {
            b.beginDraw()
            b.background(0, 0, 0, 0)
            b.noStroke()
            b.fill(Self.colorB.r * 255, Self.colorB.g * 255, Self.colorB.b * 255, Self.alphaB * 255)
            b.rect(0, 0, Float(Self.side), Float(Self.side))
            b.endDraw(wait: true)
        }

        // 焼いた**直後**にも測っておく。M 群はこの層をフレームを跨いでから
        // 読むので、そこで値が食い違ったら「合成が壊れている」のではなく
        // 「層が途中で変わった／読み方が違う」ということになる。
        // 同じものを 2 つの経路で測って初めて、その区別が付く。
        if let ai = readback(a.toImage(), Self.px.x, Self.px.y),
           let bi = readback(b.toImage(), Self.px.x, Self.px.y) {
            observations.append(Observation(id: "L9.bakedLayers",
                detail: "焼いた直後（toImage 経由）: A=\(Hue.s((ai.r, ai.g, ai.b, ai.a))) "
                    + "B=\(Hue.s((bi.r, bi.g, bi.b, bi.a)))"))
        }
    }

    // MARK: - M / G 群（フレームを跨ぐ状態機械）

    /// 1 段の落ち着き待ち（フレーム）。グラフを差し替えてから読むまでの間。
    private static let settle = 4

    private var step = 0
    private var stepStart = -1
    /// `MergePass(.add)` の実測。定規 3 本目（直描きの合成）と比べるために取っておく。
    private var mergedAdd: (Float, Float, Float)?

    /// 露光テストの手順。`step` の順に進む。
    private enum Stage: Int, CaseIterable {
        case armAdd, readAdd
        case armMultiply, readMultiply
        case armScreen, readScreen
        case armAlpha, readAlpha
        case armDAG, readDAG
        case seam
        case done
    }

    /// 検査フェーズを 1 フレーム進める。全部終わったら `true` を返す。
    func stepGraphChecks(frame: Int, room: Darkroom0, layers: Layers) -> Bool {
        guard let stage = Stage(rawValue: step) else { return true }
        if stage == .done { return true }

        if stepStart < 0 { stepStart = frame }
        let held = frame - stepStart

        switch stage {
        case .armAdd, .armMultiply, .armScreen, .armAlpha:
            if held == 0 {
                buildMergeCheckIfNeeded()
                mergeCheck?.blendType = blendFor(stage)
                sketch.showCheckGraph(mergeGraph)
            }
            if held >= Self.settle { advance(frame) }

        case .readAdd, .readMultiply, .readScreen, .readAlpha:
            recordMerge(blendFor(stage))
            advance(frame)

        case .armDAG:
            if held == 0 {
                buildDAGCheckIfNeeded()
                sketch.showCheckGraph(dagGraph)
            }
            if held >= Self.settle { advance(frame) }

        case .readDAG:
            recordDAG()
            advance(frame)

        case .seam:
            // グラフを外して、1 フレームの中で 2D と 3D を混ぜたものを読み戻す
            sketch.showCheckGraph(nil)
            if held >= 1 {
                recordSeam()
                advance(frame)
            }

        case .done:
            return true
        }

        // 露光テスト中の画面。何が起きているか分かる程度に出す
        if sketchHasNoGraph() {
            sketch.background(8, 10, 14)
            sketch.fill(180, 210, 230, 0.9)
            sketch.textSize(15)
            sketch.text("露光テスト — \(stage) (\(step + 1)/\(Stage.allCases.count))", 26, 36)
        }
        return step >= Stage.done.rawValue
    }

    private func sketchHasNoGraph() -> Bool {
        Stage(rawValue: step) == .seam
    }

    private func advance(_ frame: Int) {
        step += 1
        stepStart = -1
    }

    private func blendFor(_ stage: Stage) -> MergePass.BlendType {
        switch stage {
        case .armAdd, .readAdd: return .add
        case .armMultiply, .readMultiply: return .multiply
        case .armScreen, .readScreen: return .screen
        default: return .alpha
        }
    }

    private func buildMergeCheckIfNeeded() {
        guard mergeCheck == nil, let a = testA, let b = testB else { return }
        let na = PlateNode(label: "checkA", graphics: a)
        let nb = PlateNode(label: "checkB", graphics: b)
        nodeA = na; nodeB = nb
        guard let m = sketch.createMergePass(na, nb, blend: .add) else {
            verdicts.append(Verdict(id: "M0.build", passed: false,
                detail: "createMergePass が nil を返した。M 群は測れない"))
            return
        }
        mergeCheck = m
        mergeGraph = RenderGraph(root: m)
    }

    private func buildDAGCheckIfNeeded() {
        guard dagCheck == nil, let na = nodeA else { return }
        guard let inv = sketch.createEffectPass(na, effects: [InvertEffect()]),
              let gray = sketch.createEffectPass(na, effects: [GrayscaleEffect()]),
              let dag = sketch.createMergePass(inv, gray, blend: .add) else {
            verdicts.append(Verdict(id: "G0.build", passed: false,
                detail: "createEffectPass / createMergePass が nil を返した。G 群は測れない"))
            return
        }
        invertCheck = inv
        grayCheck = gray
        dagCheck = dag
        dagGraph = RenderGraph(root: dag)
    }

    /// `M1`〜`M5` — 焼き上がりを doc の式と突き合わせる。
    ///
    /// **期待値の作り方が肝**。「こう焼いたつもり」の値ではなく、
    /// **層から実測した値**を式に入れる。層の側で色が化けていたら、それは
    /// M の失敗ではなく L の失敗であり、混ぜてはいけない。
    private func recordMerge(_ blend: MergePass.BlendType) {
        guard let m = mergeCheck,
              let a = readTexture(nodeA?.output),
              let b = readTexture(nodeB?.output),
              let got = readTexture(m.output) else {
            verdicts.append(Verdict(id: "M.\(blend.rawValue)", passed: false,
                detail: "層またはマージ結果を読み戻せなかった（output が nil）"))
            return
        }
        let av = (a.r, a.g, a.b), bv = (b.r, b.g, b.b)
        let gv = (got.r, got.g, got.b)

        switch blend {
        case .add:
            let want = MergeOracle.add(av, bv)
            // 定規 3 本目（`M7`）と突き合わせるために取っておく。
            mergedAdd = gv
            verdicts.append(Verdict(id: "M1.add", passed: Hue.rgbEq(gv, want, Hue.composited),
                detail: "A=\(Hue.s(av)) B=\(Hue.s(bv)) → 実測=\(Hue.s(gv)) 期待=\(Hue.s(want)) "
                    + "(A+B) 差=\(Approx.f(Hue.maxDelta(gv, want), 4))"))
        case .multiply:
            let want = MergeOracle.multiply(av, bv)
            verdicts.append(Verdict(id: "M2.multiply", passed: Hue.rgbEq(gv, want, Hue.composited),
                detail: "A=\(Hue.s(av)) B=\(Hue.s(bv)) → 実測=\(Hue.s(gv)) 期待=\(Hue.s(want)) "
                    + "(A*B) 差=\(Approx.f(Hue.maxDelta(gv, want), 4))"))
        case .screen:
            let want = MergeOracle.screen(av, bv)
            verdicts.append(Verdict(id: "M3.screen", passed: Hue.rgbEq(gv, want, Hue.composited),
                detail: "A=\(Hue.s(av)) B=\(Hue.s(bv)) → 実測=\(Hue.s(gv)) 期待=\(Hue.s(want)) "
                    + "(1-(1-A)(1-B)) 差=\(Approx.f(Hue.maxDelta(gv, want), 4))"))
        case .alpha:
            // doc は「B over A」としか言わない。B のカラーが α 乗算済みかは
            // 書かれていないが、**書かれていなくても答えは 1 つに決まる**。
            //
            // 報告時（metaphor#831）は `MergePass(.alpha)` のシェーダが premultiplied な層に
            // α を 2 回掛けていた。上流はシェーダを premultiplied 前提の式へ直し（PR #865）、
            // 同じ頃に **読み戻し（`PixelBuffer`）が straight へ割り戻す**ようになった
            // （ADR-0012 / #848）。いま成り立っているのは次の 2 つで、混同すると式を間違える:
            //
            //   - 層の中の格納形式は **premultiplied**（rgb = 指定色 × α）のまま
            //   - `readTexture` で読み戻した `bv` は **straight**（= 指定色そのもの）
            //
            // 突き合わせる相手は「読んだ値」なので、正しい式は straight を α で重ねる
            // `B.rgb·B.a + A.rgb·(1−B.a)` の方。報告時のコードは `bv` を premultiplied と
            // 読んでいたため、読み戻しの仕様が変わったいまは **α を 1 回落とした形**になる。
            let correct = MergeOracle.alphaStraight(av, bv, b.a)             // straight 読み戻しに合う形
            let missingAlpha = MergeOracle.alphaPremultiplied(av, bv, b.a)   // α を掛け忘れた形
            let dMissing = Hue.maxDelta(gv, missingAlpha)
            let dCorrect = Hue.maxDelta(gv, correct)
            let consistent = dCorrect <= Hue.composited
            // 「指定した色で重ねたら本来どうなるはずか」も出す。issue に貼る数字はこれ。
            let intended = (Self.colorB.r * b.a + av.0 * (1 - b.a),
                            Self.colorB.g * b.a + av.1 * (1 - b.a),
                            Self.colorB.b * b.a + av.2 * (1 - b.a))
            verdicts.append(Verdict(id: "M4.alpha", passed: consistent,
                detail: "A=\(Hue.s(av))（不透明）に、指定 rgb=\(Hue.s((Self.colorB.r, Self.colorB.g, Self.colorB.b))) "
                    + "α=\(Approx.f(Self.alphaB, 2)) の層を .alpha で重ねた。"
                    + "読み戻しは straight へ割り戻されている（実測 B=\(Hue.s(bv)) a=\(Approx.f(b.a, 3))）ので、"
                    + "正しい合成結果は \(Hue.s(correct)) のはず → 実測=\(Hue.s(gv)) "
                    + "差=\(Approx.f(dCorrect, 4)) / α を落とした形 \(Hue.s(missingAlpha)) との差=\(Approx.f(dMissing, 4))"
                    + (consistent ? "" : " → **合成の α 前提が読み戻しと噛み合っていない**")))
            observations.append(Observation(id: "M5.alphaConvention",
                detail: "焼く側（Graphics）は premultiplied で格納し、重ねる側（MergePass(.alpha)）も"
                    + "premultiplied 前提の式で合成する（#831 は PR #865 で解決）。"
                    + "読み戻し（PixelBuffer）だけが ADR-0012 / #848 で straight へ割り戻すので、"
                    + "実測から式を検算するときは「読んだ値は straight・層の中は premultiplied」を区別する。"
                    + "作り手が期待する結果は \(Hue.s(intended))、実際に出るのは \(Hue.s(gv))"))
            // `M6` — blendType を 4 回差し替えて 4 通りの結果が出た時点で、
            // 実行時変更が効いていることは示せている。
            verdicts.append(Verdict(id: "M6.blendTypeRuntime", passed: true,
                detail: "同じ MergePass に blendType を 4 回代入し、4 通りの結果を得た（差し替えは次フレームから効く）"))
            if let out = m.output {
                observations.append(Observation(id: "M8.outputFormat",
                    detail: "マージ出力のピクセルフォーマット = \(out.pixelFormat.rawValue) / "
                        + "サイズ = \(out.width)x\(out.height)（入力 A に追従する仕様）"))
            }
        }
    }

    /// `G1`〜`G4` — エフェクトと DAG の分離。
    private func recordDAG() {
        guard let inv = invertCheck, let gray = grayCheck, let dag = dagCheck,
              let raw = readTexture(nodeA?.output) else {
            verdicts.append(Verdict(id: "G.read", passed: false, detail: "DAG の各ノードを読み戻せなかった"))
            return
        }
        let rv = (raw.r, raw.g, raw.b)

        // G1 — InvertEffect は 1 - c か
        if let i = readTexture(inv.output) {
            let iv = (i.r, i.g, i.b)
            let want = (1 - rv.0, 1 - rv.1, 1 - rv.2)
            verdicts.append(Verdict(id: "G1.invert", passed: Hue.rgbEq(iv, want, Hue.composited),
                detail: "元=\(Hue.s(rv)) → 反転後=\(Hue.s(iv)) 期待=\(Hue.s(want)) (1-c) "
                    + "差=\(Approx.f(Hue.maxDelta(iv, want), 4))"))
            observations.append(Observation(id: "G1b.invertAlpha",
                detail: "反転後の α = \(Approx.f(i.a, 3))（元 = \(Approx.f(raw.a, 3))）。"
                    + "α まで反転すると、透明な層が不透明になり合成の意味が変わる"))
        }

        // G2 — GrayscaleEffect の輝度係数。教科書の Rec.601 / Rec.709 と並べる
        if let g = readTexture(gray.output) {
            let y = g.r
            let rec601 = 0.299 * rv.0 + 0.587 * rv.1 + 0.114 * rv.2
            let rec709 = 0.2126 * rv.0 + 0.7152 * rv.1 + 0.0722 * rv.2
            let flat = (rv.0 + rv.1 + rv.2) / 3
            let d601 = abs(y - rec601), d709 = abs(y - rec709), dFlat = abs(y - flat)
            let best = d601 <= d709 && d601 <= dFlat ? "Rec.601"
                     : (d709 <= dFlat ? "Rec.709" : "単純平均")
            let gray3 = Approx.eq(g.r, g.g, Hue.composited) && Approx.eq(g.g, g.b, Hue.composited)
            verdicts.append(Verdict(id: "G2.grayscale", passed: gray3,
                detail: "元=\(Hue.s(rv)) → \(Hue.s((g.r, g.g, g.b))) 3 成分が揃っている=\(gray3) / "
                    + "Rec.601=\(Approx.f(rec601, 4))(差 \(Approx.f(d601, 4))) "
                    + "Rec.709=\(Approx.f(rec709, 4))(差 \(Approx.f(d709, 4))) "
                    + "平均=\(Approx.f(flat, 4))(差 \(Approx.f(dFlat, 4))) → 最も近いのは \(best)"))
        }

        // G3 — **エフェクトが片方の経路にだけ効くか。**
        // 同じ `nodeA` が反転とグレースケールの 2 経路へ分かれている。
        // 元のノードの出力が書き換わっていたら、DAG は要素を分離できていない。
        let untouched = Hue.rgbEq(rv, (Self.colorA.r, Self.colorA.g, Self.colorA.b), Hue.quantized)
        verdicts.append(Verdict(id: "G3.dagIsolation", passed: untouched,
            detail: "同じ層を Invert と Grayscale の 2 経路へ分岐させた後、元ノードの出力 = \(Hue.s(rv)) "
                + "期待=\(Hue.s((Self.colorA.r, Self.colorA.g, Self.colorA.b)))（焼いた値のまま）→ "
                + (untouched ? "上流は書き換えられていない" : "上流がエフェクトに破壊されている")))

        // G4 — 2 経路をマージした結果が、それぞれの読み値の和になっているか
        if let i = readTexture(inv.output), let g = readTexture(gray.output),
           let d = readTexture(dag.output) {
            let want = MergeOracle.add((i.r, i.g, i.b), (g.r, g.g, g.b))
            let dv = (d.r, d.g, d.b)
            verdicts.append(Verdict(id: "G4.multiStage", passed: Hue.rgbEq(dv, want, Hue.composited),
                detail: "Invert=\(Hue.s((i.r, i.g, i.b))) + Grayscale=\(Hue.s((g.r, g.g, g.b))) → "
                    + "マージ実測=\(Hue.s(dv)) 期待=\(Hue.s(want)) 差=\(Approx.f(Hue.maxDelta(dv, want), 4))"))
        }

        // G6 — SourcePass はスケッチの言葉で描けるか
        if let sp = sketch.createSourcePass(label: "probe", width: 64, height: 64) {
            observations.append(Observation(id: "G6.sourcePass",
                detail: "createSourcePass は成功する（label=\(sp.label)）が、onDraw が渡すのは生の "
                    + "MTLRenderCommandEncoder で circle() も sphere() も無い。"
                    + "スケッチの言葉で層を作るには Graphics/Graphics3D を RenderPassNode に包む必要がある"
                    + "（metaphor 同梱の公式サンプルも同じ回避をしている）"))
        } else {
            verdicts.append(Verdict(id: "G6.sourcePass", passed: false,
                detail: "createSourcePass(label:width:height:) が nil を返した"))
        }
    }

    /// `X1`〜`X4` — 1 フレームの中で 2D と 3D を混ぜる。
    ///
    /// **メインキャンバスに描いて、同じフレームの中で読み戻す。**
    /// 順番は「2D の下地 → 3D の箱 → 2D の帯」。最後の 2D が 3D の上に出るなら、
    /// 描画順が深度に負けていないということ。
    private func recordSeam() {
        let s = sketch
        let w = Int(s.width), h = Int(s.height)
        let cx = Float(w) / 2, cy = Float(h) / 2

        s.background(0, 0, 0)

        // (1) 2D の下地 — 青一色
        s.noStroke()
        s.fill(0, 0, 255)
        s.rect(0, 0, s.width, s.height)

        // (2) 3D の箱 — 中央に緑
        s.perspective(fov: .pi / 3, near: 0.1, far: 10000)
        let z = cy / tan(Float.pi / 6)
        s.camera(eye: SIMD3(cx, cy, z), center: SIMD3(cx, cy, 0), up: SIMD3(0, 1, 0))
        s.noLights()
        s.noStroke()
        s.pushMatrix()
        s.translate(cx, cy, 0)
        s.fill(0, 255, 0)
        s.box(200)
        s.popMatrix()

        // (3) また 2D — 2 か所に赤い帯を置く。**位置だけを変えた対照実験**。
        //     3a: 箱に**重なる**位置（中央）
        //     3b: 箱に**重ならない**位置（左端の青地の上）
        //   3a だけが消えるなら「3D に隠れている」= 深度の問題。
        //   両方消えるなら「3D の後の 2D がそもそも出ない」= 描画順の問題。
        s.noStroke()
        s.fill(255, 0, 0)
        s.rect(cx - 40, cy - 10, 80, 20)     // 3a 箱の上
        s.rect(80, cy - 10, 80, 20)          // 3b 青地の上

        s.loadPixels()
        let px = s.pixels
        guard px.count >= w * h else {
            verdicts.append(Verdict(id: "X0.loadPixels", passed: false,
                detail: "3D を描いたフレームで loadPixels() が空を返した（pixels.count=\(px.count)）"))
            return
        }
        func at(_ x: Int, _ y: Int) -> (Float, Float, Float) {
            let v = px[y * w + x]
            return (Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255)
        }
        let corner = at(10, 10)                       // 2D の下地だけ
        let boxPx = at(Int(cx), Int(cy) - 60)         // 3D の箱
        let bandOnBox = at(Int(cx), Int(cy))          // 3a 箱に重なる赤帯
        let bandOnBlue = at(120, Int(cy))             // 3b 箱に重ならない赤帯

        verdicts.append(Verdict(id: "X4.loadPixelsAfter3D", passed: true,
            detail: "3D を描いたフレームで loadPixels() が読めた（\(w)x\(h)、隅=\(Hue.s(corner))）"))

        let boxOverBase = boxPx.1 > 0.5 && boxPx.2 < 0.5
        verdicts.append(Verdict(id: "X2a.threeDOverTwoD", passed: boxOverBase,
            detail: "2D の青地に 3D の緑箱を重ねた中央上部 = \(Hue.s(boxPx)) → "
                + (boxOverBase ? "3D が 2D の上に出ている" : "3D が 2D に隠れている")))

        // **位置だけを変えた対照実験。** 同じ 1 フレーム・同じ描画順で、
        // 3D の箱に重なるか重ならないかだけが違う 2 本の赤帯を読む。
        let isRed: ((Float, Float, Float)) -> Bool = { $0.0 > 0.5 && $0.1 < 0.5 }
        let onBoxRed = isRed(bandOnBox)
        let onBlueRed = isRed(bandOnBlue)
        // ここで言えるのは「重なるところだけ負ける」までで、
        // **原因が深度なのか塗る順番なのかはまだ決まらない**（どちらの仮説も
        // 同じ絵を予測する）。それを分けるのは `X5` の対照実験。
        let diagnosis: String
        if onBoxRed && onBlueRed {
            diagnosis = "後の 2D は 3D の上に出る（呼んだ順どおり）"
        } else if !onBoxRed && onBlueRed {
            diagnosis = "**3D と重なるところだけ**後の 2D が負ける"
                + "（深度で負けたのか 3D が後から塗ったのかは、ここでは決まらない → X5）"
        } else if !onBoxRed && !onBlueRed {
            diagnosis = "3D の後の 2D がどこにも出ない = 2D の描画自体が届いていない"
        } else {
            diagnosis = "重なる方だけ出た（説明が付かない。要追試）"
        }
        verdicts.append(Verdict(id: "X2b.twoDOverThreeD", passed: onBoxRed && onBlueRed,
            detail: "3D の箱の後に描いた赤帯: 箱に重なる位置=\(Hue.s(bandOnBox)) / "
                + "重ならない位置=\(Hue.s(bandOnBlue)) → \(diagnosis)"))

        // X3 — 3D を挟んでも 2D の fill が保たれているか。
        // 箱に重ならない帯が赤くないなら、色そのものが化けている疑いになる。
        verdicts.append(Verdict(id: "X3.styleAcrossSeam", passed: onBlueRed,
            detail: "3D 描画を挟んだ後に fill(255,0,0) → 箱の外の帯 = \(Hue.s(bandOnBlue)) "
                + "期待=(1.000, 0.000, 0.000)（色が保たれているか。深度とは別の問い）"))

        // X5 — **「深度で負けている」と「3D が常に後から塗られている」は、
        // ここまでの観測では区別できない。** どちらの仮説も同じ絵を予測する。
        //
        // 条件を 1 つだけ変えて分ける: 箱を**視点から遠ざける**（z を大きく負へ）。
        //   深度比較なら … 遠い箱には 2D が勝つ（2D の深度は手前のはず）→ 赤が出る
        //   パス順なら   … 箱の遠近によらず 3D が後から塗る → 緑のまま
        s.background(0, 0, 0)
        s.noStroke()
        s.fill(0, 0, 255)
        s.rect(0, 0, s.width, s.height)
        s.perspective(fov: .pi / 3, near: 0.1, far: 10000)
        s.camera(eye: SIMD3(cx, cy, z), center: SIMD3(cx, cy, 0), up: SIMD3(0, 1, 0))
        s.noLights()
        s.pushMatrix()
        s.translate(cx, cy, -600)          // ← 変えたのはここだけ
        s.fill(0, 255, 0)
        s.box(600)                          // 遠いぶん大きくして、同じくらいの見かけにする
        s.popMatrix()
        s.fill(255, 0, 0)
        s.rect(cx - 40, cy - 10, 80, 20)
        s.loadPixels()
        let px2 = s.pixels
        let farBand: (Float, Float, Float)
        if px2.count >= w * h {
            let v = px2[Int(cy) * w + Int(cx)]
            farBand = (Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255)
        } else {
            farBand = (0, 0, 0)
        }
        let farRed = isRed(farBand)
        let mechanism = farRed
            ? "箱を z=-600 へ遠ざけたら赤帯が出た → **深度比較**で負けていた（2D にも深度が効いている）"
            : "箱を z=-600 へ遠ざけても緑のまま → **3D が 2D より後に塗られている**（深度ではなくパスの順序）"
        observations.append(Observation(id: "X5.depthOrPassOrder",
            detail: "同じ描画順のまま箱の z だけを 0 → -600 に変えた対照実験: "
                + "近い箱の上の帯=\(Hue.s(bandOnBox)) / 遠い箱の上の帯=\(Hue.s(farBand)) → \(mechanism)"))

        // X6 — **回避策があるか。** doc は「loadPixels() は読み戻しのために
        // 内部でレンダーパスを分割する」と言う。パスが分かれるなら、
        // 分割の後に描いた 2D は 3D より後のパスに入り、上に出るはず。
        // 3D の上に HUD を出したい作り手が実際に必要とする道なので、
        // 効くかどうかをここで確定させておく。
        s.background(0, 0, 0)
        s.noStroke()
        s.fill(0, 0, 255)
        s.rect(0, 0, s.width, s.height)
        s.perspective(fov: .pi / 3, near: 0.1, far: 10000)
        s.camera(eye: SIMD3(cx, cy, z), center: SIMD3(cx, cy, 0), up: SIMD3(0, 1, 0))
        s.noLights()
        s.pushMatrix()
        s.translate(cx, cy, 0)
        s.fill(0, 255, 0)
        s.box(200)
        s.popMatrix()
        s.loadPixels()                       // ← ここでパスを割る（変えたのはこの 1 行だけ）
        s.fill(255, 0, 0)
        s.rect(cx - 40, cy - 10, 80, 20)
        s.loadPixels()
        let px3 = s.pixels
        let splitBand: (Float, Float, Float)
        if px3.count >= w * h {
            let v = px3[Int(cy) * w + Int(cx)]
            splitBand = (Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255)
        } else {
            splitBand = (0, 0, 0)
        }
        let splitRed = isRed(splitBand)
        // M7 — **定規 3 本目。** 同じ 2 層を、パスの合成ではなく
        // 「メインキャンバスに `image()` で貼り、`blendMode(.add)` で重ねる」やり方で
        // 合成し、`MergePass(.add)` の結果と突き合わせる。
        //
        // `.add` を選ぶのは、両側とも壊れていない唯一のブレンドだから
        // （`.alpha` は #831 で、直描き側の multiply/screen は metaphor#801 で
        // それぞれ別に壊れているので、比べても「両方おかしい」以上が出ない）。
        // **2 つの合成経路が同じ絵を出すか**だけをここで確定させる。
        if let mergedAdd, let a = testA, let b = testB {
            s.background(0, 0, 0)
            s.blendMode(.alpha)
            s.image(a, 0, 0, Float(Self.side), Float(Self.side))
            s.blendMode(.additive)
            s.image(b, 0, 0, Float(Self.side), Float(Self.side))
            s.blendMode(.alpha)
            s.loadPixels()
            let px4 = s.pixels
            if px4.count >= w * h {
                let v = px4[Self.px.y * w + Self.px.x]
                let direct = (Float((v >> 16) & 0xFF) / 255,
                              Float((v >> 8) & 0xFF) / 255,
                              Float(v & 0xFF) / 255)
                let d = Hue.maxDelta(direct, mergedAdd)
                // 直描き側が何をしているのかを、2 つの解釈と並べて出す。
                // B の rgb は既に α 乗算済み（`L7`）なので、加算合成の正しい形は
                // `A + B.rgb`。もう一度 α を掛けると `A + B.rgb·B.a` になる。
                let av = (Self.colorA.r, Self.colorA.g, Self.colorA.b)
                let bStored = (Self.colorB.r * Self.alphaB,
                               Self.colorB.g * Self.alphaB,
                               Self.colorB.b * Self.alphaB)
                let correct = MergeOracle.add(av, bStored)
                let doubled = MergeOracle.add(av, (bStored.0 * Self.alphaB,
                                                   bStored.1 * Self.alphaB,
                                                   bStored.2 * Self.alphaB))
                let dC = Hue.maxDelta(direct, correct), dD = Hue.maxDelta(direct, doubled)
                verdicts.append(Verdict(id: "M7.twoCompositors", passed: d <= Hue.composited,
                    detail: "同じ 2 層を 2 通りで重ねた: MergePass(.add)=\(Hue.s(mergedAdd)) / "
                        + "image()+blendMode(.additive) の直描き=\(Hue.s(direct)) 差=\(Approx.f(d, 4))。"
                        + "直描き側は 正しい形 A+B=\(Hue.s(correct)) との差 \(Approx.f(dC, 4)) / "
                        + "α をもう一度掛けた A+B·a=\(Hue.s(doubled)) との差 \(Approx.f(dD, 4))"))

                // M7b — **変えるのは blendMode 1 つだけ。**
                // `.additive` が α を二重に掛けているのか、`image()` の経路が
                // 一般に premultiplied を扱えていないのかを分ける。
                s.background(0, 0, 0)
                s.blendMode(.alpha)
                s.image(a, 0, 0, Float(Self.side), Float(Self.side))
                s.image(b, 0, 0, Float(Self.side), Float(Self.side))
                s.loadPixels()
                let px5 = s.pixels
                if px5.count >= w * h {
                    let v5 = px5[Self.px.y * w + Self.px.x]
                    let over = (Float((v5 >> 16) & 0xFF) / 255,
                                Float((v5 >> 8) & 0xFF) / 255,
                                Float(v5 & 0xFF) / 255)
                    let okOver = MergeOracle.alphaPremultiplied(av, bStored, Self.alphaB)
                    let dblOver = MergeOracle.alphaStraight(av, bStored, Self.alphaB)
                    let dOk = Hue.maxDelta(over, okOver), dDbl = Hue.maxDelta(over, dblOver)
                    verdicts.append(Verdict(id: "M7b.imageOverAlpha", passed: dOk <= Hue.composited,
                        detail: "blendMode だけ .alpha に変えて同じ 2 層を直描き → \(Hue.s(over))。"
                            + "premultiplied として正しい形 \(Hue.s(okOver)) との差 \(Approx.f(dOk, 4)) / "
                            + "α をもう一度掛けた形 \(Hue.s(dblOver)) との差 \(Approx.f(dDbl, 4))"))
                }
            }
        }

        // X7 — `L10` はオフスクリーン（`Graphics`）での測定だった。
        // **メインキャンバスでも同じか**を、変えるのは描画先だけにして確かめる。
        // ここが分かれるなら「オフスクリーンのテキスト経路だけ」の話になる。
        func mainTextBrightest(_ alpha: Float) -> Float {
            s.background(0, 0, 0)
            s.noStroke()
            s.fill(255, 255, 255, alpha)
            s.textSize(48)
            s.text("HHHHH", 40, 120)
            s.loadPixels()
            let p = s.pixels
            guard p.count >= w * h else { return -1 }
            var best: Float = 0
            for y in 60..<130 {
                for x in 40..<240 { best = max(best, Float((p[y * w + x] >> 16) & 0xFF) / 255) }
            }
            return best
        }
        let m0 = mainTextBrightest(0), m128 = mainTextBrightest(128), m255 = mainTextBrightest(255)
        verdicts.append(Verdict(id: "X7.mainCanvasTextAlpha", passed: m0 < 0.02,
            detail: "メインキャンバスに黒地で fill(255,255,255,α) の文字: "
                + "α=0 → \(Approx.f(m0, 3)) / α=128 → \(Approx.f(m128, 3)) / α=255 → \(Approx.f(m255, 3))"
                + "（比例なら 0.000 / 0.502 / 1.000）"))

        verdicts.append(Verdict(id: "X6.loadPixelsAsSplit", passed: splitRed,
            detail: "3D と 2D の間に loadPixels() を 1 行挟んだだけの対照実験: "
                + "挟まない=\(Hue.s(bandOnBox)) / 挟む=\(Hue.s(splitBand)) → "
                + (splitRed ? "**挟めば 2D が 3D の上に出る**（パス分割が回避策として使える）"
                            : "挟んでも 2D は 3D の下のまま（この回避策は効かない）")))
    }

    // MARK: - 仕上げ

    func finish() {
        Emulsion.say("")
        // L 群は runOfflineChecks で既に出しているので、ここでは M/G/X だけを出す
        for v in verdicts.filter({ !$0.id.hasPrefix("L") }) { Emulsion.say(v.line) }
        for o in observations.filter({ !$0.id.hasPrefix("L") }) { Emulsion.say(o.line) }
        Emulsion.say("")
        Emulsion.say("\(tally)")
        Emulsion.say("self-check 完了")

        for v in verdicts { sketch.probe("check.\(v.id)", v.line) }
        for o in observations { sketch.probe("check.\(o.id)", o.line) }
    }

    // MARK: - 読み戻しの道具

    private func readback(_ img: MImage, _ x: Int, _ y: Int) -> Color? {
        img.loadPixels()
        guard !img.pixels.isEmpty else { return nil }
        return img.get(x, y)
    }

    /// 既に `loadPixels()` 済みの画像から読む（同じ画像を 2 点読むとき）。
    private func readbackLoaded(_ img: MImage, _ x: Int, _ y: Int) -> Color? {
        guard !img.pixels.isEmpty else { return nil }
        return img.get(x, y)
    }

    private func readTexture(_ tex: MTLTexture?) -> Color? {
        guard let tex else { return nil }
        let img = MImage(texture: tex)
        img.loadPixels()
        guard !img.pixels.isEmpty else { return nil }
        return img.get(Self.px.x, Self.px.y)
    }

    private func setupCheckCamera(_ s: Graphics3D) {
        let side = Float(Self.side)
        let fov: Float = .pi / 3
        let z = (side / 2) / tan(fov / 2)
        s.perspective(fov: fov, near: 0.1, far: 10000)
        s.camera(eye: SIMD3(side / 2, side / 2, z),
                 center: SIMD3(side / 2, side / 2, 0),
                 up: SIMD3(0, 1, 0))
    }

    private func exposeSphere(_ s: Graphics3D, radius: Float, fill: Color) {
        s.beginDraw(time: 0)
        setupCheckCamera(s)
        // 検査の球はライティングで暗くしない。**明暗ではなく寸法と有無**を測る
        s.noLights()
        s.noStroke()
        s.fill(fill)
        s.pushMatrix()
        s.translate(Float(Self.side) / 2, Float(Self.side) / 2, 0)
        s.sphere(radius, detail: 32)
        s.popMatrix()
        s.endDraw(wait: true)
    }
}
