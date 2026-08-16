import Foundation
import metaphor

// 層 C — **フレームを跨がないと測れない色**。
//
// 層 B は `createGraphics` のオフスクリーンで完結したが、そこには 2 つ届かないものがある。
//
//  1. `linearGradient` / `radialGradient` / `pushStyle` は `Graphics` に無い。
//     本編キャンバスに描いて `previousFrame()` で読み戻すしかない。
//  2. ポストエフェクトは合成後のフレームに掛かる。定義上オフスクリーンには乗らない。
//
// どちらも「このフレームで描く → 次のフレームで読む」の 2 拍が要る。起動直後の数フレームを
// 校正に使い、終わったら本編へ明け渡す。**校正が終わるまで作品は描き始めない。**

@MainActor
final class Runtime {
    /// 1 段 = 「描く」フレームと「読む」フレームの対。
    private struct Stage {
        let id: String
        let paint: (Sketch0816Prism, Runtime) -> Void
        let judge: (MImage, Runtime) -> Verdict
    }

    private enum Phase { case latency, stages, done }
    private var phase: Phase = .latency

    private var index = 0
    /// `paint` したフレームからの経過。`-1` はまだ何も描いていない状態。
    private var sincePaint = -1
    private(set) var finished = false

    /// 届いた入力の種類。判定はせず、経路が生きているかを記録するだけ。
    private var inputs: [String] = []

    var isCalibrating: Bool { !finished }

    func noteInput(_ kind: String) {
        if !inputs.contains(kind) { inputs.append(kind) }
    }

    // MARK: - フィードバックの遅延

    /// `previousFrame()` が何フレーム前を返すか。**決め打ちしないで実測する。**
    ///
    /// 最初は 1 と決めて書いたが、そのままだと各段が 1 つ前の段のパターンを読み、
    /// グラデーションの検査が総崩れになった（G2 が G1 の絵を読んでいた）。
    /// 全滅の原因が「metaphor の色がおかしい」ではなく「こちらの読むタイミング」なので、
    /// **測ってから使う**。ここを飛ばすと上流へ誤報を出す。
    private(set) var feedbackLatency = 1
    private var latencyFrame = 0
    private var latencySamples: [Int] = []
    /// 遅延測定に使うフレーム数。1 フレームごとに違う濃さの赤で全面を塗る。
    private static let latencyProbes = 7

    // MARK: - 進行

    /// 校正を 1 フレーム進める。`draw()` の先頭から、本編より先に呼ぶ。
    func step(_ s: Sketch0816Prism) {
        switch phase {
        case .latency: stepLatency(s)
        case .stages: stepStages(s)
        case .done: break
        }
    }

    /// 各フレームを一意な濃さで塗り、読み戻した濃さから「何フレーム前か」を逆算する。
    private func stepLatency(_ s: Sketch0816Prism) {
        // 読む（前フレームまでに塗った色が返ってくるはず）。
        if latencyFrame > 0, let frame = s.previousFrame() {
            frame.loadPixels()
            let c = frame.get(Int(frame.width / 2), Int(frame.height / 2))
            let painted = Int((c.r * Float(Self.latencyProbes + 1)).rounded())
            // 濃さ p を塗ったのはフレーム p-1（塗る操作がカウンタを進めた後にあるため、
            // フレーム f が塗る濃さは f+1 番目になる）。ここを f-p と書いて 1 つ小さく
            // 見積もり、各段が 1 つ前の段の絵を読む形で全滅した。**+1 はその修正。**
            if painted >= 1, painted <= latencyFrame {
                latencySamples.append(latencyFrame - painted + 1)
            }
        }

        latencyFrame += 1
        if latencyFrame > Self.latencyProbes {
            // 最頻値を採る。1 サンプルだけで決めると、起動直後の未初期化フレームに引かれる。
            let counts = latencySamples.reduce(into: [Int: Int]()) { $0[$1, default: 0] += 1 }
            let decided = counts.max { $0.value < $1.value }?.key
            feedbackLatency = max(decided ?? 1, 1)
            s.append([Verdict(id: "G-0.feedbackLatency", passed: decided != nil,
                detail: "1 フレームごとに濃さを変えて全面を塗り、previousFrame() の濃さから逆算"
                    + " / サンプル=\(latencySamples.map(String.init).joined(separator: ",")) → 遅延 \(feedbackLatency) フレーム"
                    + " / 以降の段はこの遅延ぶん待ってから読む")])
            phase = .stages
            return
        }

        // 塗る。濃さがそのままフレーム番号になる。
        let level = Float(latencyFrame) / Float(Self.latencyProbes + 1)
        s.blendMode(.opaque)
        s.background(Color(r: level, g: 0, b: 0))
    }

    private func stepStages(_ s: Sketch0816Prism) {
        let stages = Self.stages

        if sincePaint >= 0 {
            sincePaint += 1
            // 遅延ぶん経つまでは何も描かない。描き替えると読む対象が変わってしまう。
            guard sincePaint >= feedbackLatency else { return }

            let stage = stages[index]
            if let frame = s.previousFrame() {
                frame.loadPixels()
                s.append([stage.judge(frame, self)])
            } else {
                s.append([Verdict(id: stage.id, passed: false,
                    detail: "previousFrame() が nil を返した。合成後のフレームを読めない")])
            }
            index += 1
            sincePaint = -1
        }

        guard index < stages.count else {
            finish(s)
            return
        }
        stages[index].paint(s, self)
        sincePaint = 0
    }

    private func finish(_ s: Sketch0816Prism) {
        phase = .done
        finished = true
        s.clearPostEffects()
        // 本編は前フレームを読まない。フィードバックはフレームごとのコピーを伴うので戻す。
        s.disableFeedback()
        s.append([Verdict(id: "I1.inputPath", passed: true,
            detail: "校正中に届いた入力: \(inputs.isEmpty ? "なし（無人起動）" : inputs.joined(separator: ", "))"
                + " / 判定はせず経路の記録のみ。人が触ると mouseMoved / keyPressed が増える")])
    }

    // MARK: - 読み取り

    // 読み取りは常に **画像の実寸に対する相対座標**で行う。`previousFrame()` が Retina の
    // 実ピクセル（論理サイズの 2 倍）で返ってきても、相対で読む限り同じ式が当たる。
    // 実寸そのものは G0 が記録する。

    private static func rgb(_ c: Color) -> (Float, Float, Float) { (c.r, c.g, c.b) }

    // MARK: - 段の定義

    private static let stages: [Stage] = [

        // G0: 本編キャンバスを読み戻す土俵を作る。
        //     `previousFrame()` の解像度が論理サイズと違う（Retina）と、以降の読み取り座標が
        //     全部ずれる。左上だけを赤くした板を焼いて、倍率と向きを同時に確定させる。
        Stage(id: "G0.frameGeometry",
            paint: { s, _ in
                s.blendMode(.opaque)
                s.background(Color.black)
                s.noStroke()
                s.fill(Color.red)
                s.rect(0, 0, s.width / 2, s.height / 2)
            },
            judge: { img, _ in
                let topLeft = img.get(Int(img.width * 0.25), Int(img.height * 0.25))
                let bottomLeft = img.get(Int(img.width * 0.25), Int(img.height * 0.75))
                let isRed: (Color) -> Bool = { $0.r > 0.5 && $0.g < 0.25 && $0.b < 0.25 }
                let upright = isRed(topLeft) && !isRed(bottomLeft)
                return Verdict(id: "G0.frameGeometry", passed: upright,
                    detail: "previousFrame \(Int(img.width))x\(Int(img.height))"
                        + " / 上 1/4=\(Hue.s(rgb(topLeft))) 下 1/4=\(Hue.s(rgb(bottomLeft)))"
                        + " → \(upright ? "描画座標と同じ向き" : "向きが一致しない")")
            }),

        // G1: `linearGradient` の既定の軸（vertical）。
        //     端点の色と、途中が単調に混ざるかを見る。赤 → 青にすると成分ごとに追える。
        Stage(id: "G1.linearVertical",
            paint: { s, _ in
                s.blendMode(.opaque)
                s.background(Color.black)
                s.linearGradient(0, 0, s.width, s.height, Color.red, Color.blue, axis: .vertical)
            },
            judge: { img, _ in
                let top = img.get(Int(img.width / 2), Int(img.height * 0.02))
                let mid = img.get(Int(img.width / 2), Int(img.height / 2))
                let bottom = img.get(Int(img.width / 2), Int(img.height * 0.98))
                let ok = top.r > 0.8 && top.b < 0.2
                    && bottom.b > 0.8 && bottom.r < 0.2
                    && abs(mid.r - 0.5) < 0.2 && abs(mid.b - 0.5) < 0.2
                return Verdict(id: "G1.linearVertical", passed: ok,
                    detail: "上=\(Hue.s(rgb(top))) 期待≈(1,0,0) / 中=\(Hue.s(rgb(mid))) 期待≈(0.5,0,0.5)"
                        + " / 下=\(Hue.s(rgb(bottom))) 期待≈(0,0,1)")
            }),

        // G2: `axis: .horizontal`。左が c1、右が c2 になるか。
        Stage(id: "G2.linearHorizontal",
            paint: { s, _ in
                s.blendMode(.opaque)
                s.background(Color.black)
                s.linearGradient(0, 0, s.width, s.height, Color.red, Color.blue, axis: .horizontal)
            },
            judge: { img, _ in
                let left = img.get(Int(img.width * 0.02), Int(img.height / 2))
                let right = img.get(Int(img.width * 0.98), Int(img.height / 2))
                let ok = left.r > 0.8 && left.b < 0.2 && right.b > 0.8 && right.r < 0.2
                return Verdict(id: "G2.linearHorizontal", passed: ok,
                    detail: "左=\(Hue.s(rgb(left))) 期待≈(1,0,0) / 右=\(Hue.s(rgb(right))) 期待≈(0,0,1)")
            }),

        // G3: `axis: .diagonal`。左上 → 右下。**縦横と区別が付く読み方をする**。
        //     対角なら左下と右上がどちらも中間色になり、縦・横のどちらとも違う指紋になる。
        Stage(id: "G3.linearDiagonal",
            paint: { s, _ in
                s.blendMode(.opaque)
                s.background(Color.black)
                s.linearGradient(0, 0, s.width, s.height, Color.red, Color.blue, axis: .diagonal)
            },
            judge: { img, _ in
                let topLeft = img.get(Int(img.width * 0.02), Int(img.height * 0.02))
                let bottomRight = img.get(Int(img.width * 0.98), Int(img.height * 0.98))
                let bottomLeft = img.get(Int(img.width * 0.02), Int(img.height * 0.98))
                let topRight = img.get(Int(img.width * 0.98), Int(img.height * 0.02))
                let endsOK = topLeft.r > 0.8 && bottomRight.b > 0.8
                // 逆対角の 2 点がどちらも中間なら、縦でも横でもなく対角だと言える。
                let cornersMixed = abs(bottomLeft.r - bottomLeft.b) < 0.35 && abs(topRight.r - topRight.b) < 0.35
                return Verdict(id: "G3.linearDiagonal", passed: endsOK && cornersMixed,
                    detail: "左上=\(Hue.s(rgb(topLeft))) 右下=\(Hue.s(rgb(bottomRight))) 期待≈(1,0,0)/(0,0,1)"
                        + " / 左下=\(Hue.s(rgb(bottomLeft))) 右上=\(Hue.s(rgb(topRight))) 期待=どちらも中間")
            }),

        // G4: `radialGradient`。中心が内側の色、縁が外側の色になるか。
        Stage(id: "G4.radialGradient",
            paint: { s, _ in
                s.blendMode(.opaque)
                s.background(Color.black)
                s.radialGradient(s.width / 2, s.height / 2, s.height * 0.4,
                                 Color.white, Color(r: 0, g: 0, b: 0), segments: 64)
            },
            judge: { img, _ in
                let center = img.get(Int(img.width / 2), Int(img.height / 2))
                let midway = img.get(Int(img.width / 2), Int(img.height * 0.31))
                let outside = img.get(Int(img.width * 0.06), Int(img.height / 2))
                let ok = center.r > 0.85 && outside.r < 0.15 && midway.r > 0.15 && midway.r < 0.85
                return Verdict(id: "G4.radialGradient", passed: ok,
                    detail: "中心=\(Hue.s(rgb(center))) 期待≈(1,1,1) / 途中=\(Hue.s(rgb(midway))) 期待=中間"
                        + " / 外=\(Hue.s(rgb(outside))) 期待≈(0,0,0)")
            }),

        // G5: `segments` を極端に減らす。既定は 36 で、3 まで落とすと円ではなく三角形になるはず。
        //     **退化した引数で落ちないこと**が主眼（`createGraphics` の 0 サイズは実際に落ちた
        //     → metaphor#798）。中心は内側の色のままかも見る。
        Stage(id: "G5.radialSegmentsLow",
            paint: { s, _ in
                s.blendMode(.opaque)
                s.background(Color.black)
                s.radialGradient(s.width / 2, s.height / 2, s.height * 0.4,
                                 Color.white, Color(r: 0, g: 0, b: 0), segments: 3)
            },
            judge: { img, _ in
                let center = img.get(Int(img.width / 2), Int(img.height / 2))
                let ok = center.r > 0.7
                return Verdict(id: "G5.radialSegmentsLow", passed: ok,
                    detail: "segments=3 で中心=\(Hue.s(rgb(center))) 期待≈(1,1,1) / 落ちずに描けた")
            }),

        // G6: `pushStyle` / `popStyle` は colorMode まで退避するか。
        //     `Graphics` には無い API なので、本編キャンバスでしか測れない（層 B の B6 と対になる）。
        Stage(id: "G6.styleStack",
            paint: { s, _ in
                s.blendMode(.opaque)
                s.colorMode(.rgb, 255)
                s.background(Color.black)
                s.noStroke()
                s.pushStyle()
                s.colorMode(.rgb, 1)
                s.popStyle()
                s.fill(255, 0, 0)      // 復元されていれば純赤
                s.rect(s.width * 0.25, s.height * 0.25, s.width * 0.5, s.height * 0.5)
                s.colorMode(.rgb, 255) // 後片付け（次の段へ持ち越さない）
            },
            judge: { img, _ in
                let got = img.get(Int(img.width / 2), Int(img.height / 2))
                let restored = got.r > 0.85 && got.g < 0.15 && got.b < 0.15
                let finite = got.r.isFinite && got.g.isFinite && got.b.isFinite
                return Verdict(id: "G6.styleStack", passed: finite,
                    detail: "pushStyle → colorMode(.rgb,1) → popStyle の後に fill(255,0,0) → \(Hue.s(rgb(got)))"
                        + " → colorMode は \(restored ? "popStyle で復元される" : "popStyle で復元されない")"
                        + " / 判定は読めることのみ（doc に記載が無い）")
            }),

        // P1: **ポストエフェクトは `previousFrame()` に乗らない。**
        //
        //     最初は「saturation=0 なら灰色が返る」と期待して書いたが、純赤のまま返った。
        //     実装を読むと理由がはっきりする（`MetaphorRenderer`）:
        //
        //       - `capturePreviousFrame` がコピーするのは `textureManager.colorTexture`
        //         （＝エフェクトを通す**前**の描画結果）で、しかもフレームの先頭で走る
        //       - エフェクトは後段の `pipeline.apply(source:)` が**別のテクスチャ**へ出す
        //       - `saveFrame` はそちら（`outputTexture`）をコピーする
        //
        //     フィードバックにエフェクトが乗るとフレームごとに効果が累積してしまうので、
        //     乗らないのは設計として妥当。ただし doc は「前フレームのレンダリング結果」としか
        //     書いておらず、前段・後段のどちらかは明言していない。**この段はその性質を固定する。**
        //     エフェクトが実際に効いているかは画面（`aberration` の場面）で確かめる。
        Stage(id: "P1.colorGradePreFeedback",
            paint: { s, _ in
                s.clearPostEffects()
                s.addPostEffect(ColorGradeEffect(saturation: 0))
                s.blendMode(.opaque)
                s.background(Color.black)
                s.noStroke()
                s.fill(Color.red)
                s.rect(0, 0, s.width, s.height)
            },
            judge: { img, _ in
                let got = img.get(Int(img.width / 2), Int(img.height / 2))
                let spread = max(got.r, got.g, got.b) - min(got.r, got.g, got.b)
                // エフェクト前が返るので、純赤は純赤のまま（成分差が大きいまま）であるべき。
                let untouched = spread > 0.9
                return Verdict(id: "P1.colorGradePreFeedback", passed: untouched,
                    detail: "純赤の全面に ColorGradeEffect(saturation: 0) を掛けて previousFrame() → "
                        + "\(Hue.s(rgb(got))) 成分差=\(Approx.f(spread, 3))"
                        + " 期待=純赤のまま（フィードバックはエフェクト適用**前**の colorTexture）"
                        + " / 灰色が返るならエフェクトが累積する設計ということになる")
            }),

        // P2: P1 と同じ性質を、別のエフェクトで裏取りする。
        //     色収差は「白い縁に色を乗せる」エフェクトなので、白黒の鋭い境目を作れば
        //     効いているかどうかが最も出やすい。ここでも色が乗らなければ、
        //     「エフェクトがフィードバックに乗らない」のがエフェクト固有ではないと言える。
        Stage(id: "P2.aberrationPreFeedback",
            paint: { s, _ in
                s.clearPostEffects()
                s.addPostEffect(ChromaticAberrationEffect(intensity: 0.03))
                s.blendMode(.opaque)
                s.background(Color.black)
                s.noStroke()
                s.fill(Color.white)
                s.rect(0, 0, s.width / 2, s.height)   // 画面の左半分だけ白 → 中央に鋭い境目
            },
            judge: { img, _ in
                // 境目の少し外（黒側）を読む。色収差があれば、ここに色が漏れる。
                var worst: (x: Int, spread: Float, color: Color) = (0, 0, Color.black)
                for dx in 0...24 {
                    let x = Int(img.width / 2) + dx
                    let c = img.get(min(x, Int(img.width) - 1), Int(img.height / 2))
                    let spread = max(c.r, c.g, c.b) - min(c.r, c.g, c.b)
                    if spread > worst.spread { worst = (dx, spread, c) }
                }
                let untinted = worst.spread <= 0.05
                return Verdict(id: "P2.aberrationPreFeedback", passed: untinted,
                    detail: "白黒の境目に ChromaticAberrationEffect(0.03) を掛けて previousFrame() → "
                        + "境目から +\(worst.x)px の最大成分差=\(Approx.f(worst.spread, 3)) \(Hue.s(rgb(worst.color)))"
                        + " 期待=色が乗らない（P1 と同じくエフェクト適用前）"
                        + " / 画面で効いていることは aberration の場面で確認する")
            }),
    ]
}
