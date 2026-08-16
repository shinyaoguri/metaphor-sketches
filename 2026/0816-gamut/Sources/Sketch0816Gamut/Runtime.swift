import Foundation
import metaphor

// メインキャンバスでしか確かめられない検査。
//
// `Graphics`（オフスクリーン）の公開メンバーは 62 個で、Sketch より狭い。
// **linearGradient / radialGradient / 色付き vertex / pushStyle・popStyle が無い**
// （doc は「ほか 60 件の描画・変換メンバーは Sketch API と同名・同挙動」と書いているが、
// 実体はこれらを含まない）。なのでここだけはメインキャンバスへ描いて `loadPixels()` で読む。
//
// フレームを跨ぐ検査（blendMode が次フレームへ漏れないか）もここに置く。

/// メインキャンバスの `pixels` を読む。
///
/// パック済み UInt32 で `(A << 24) | (R << 16) | (G << 8) | B`、添字は `y * width + x`
/// （0816-adversary の `PixelReader` と同じ約束）。並びは `R0.packing` で実測して確かめる。
struct MainReader {
    let w: Int
    let h: Int
    let buf: UnsafeMutableBufferPointer<UInt32>

    func rgba(_ x: Float, _ y: Float) -> RGBA8 {
        let xi = Int(x.rounded()), yi = Int(y.rounded())
        guard xi >= 0, yi >= 0, xi < w, yi < h, buf.count >= w * h else {
            return RGBA8(-1, -1, -1, -1)
        }
        let p = buf[yi * w + xi]
        return RGBA8(Int((p >> 16) & 0xFF), Int((p >> 8) & 0xFF),
                     Int(p & 0xFF), Int((p >> 24) & 0xFF))
    }
}

/// 検査パッチ 1 枚の置き場。
struct Patch {
    let x: Float, y: Float, w: Float, h: Float
    var cx: Float { x + w / 2 }
    var cy: Float { y + h / 2 }
    var right: Float { x + w }
    var bottom: Float { y + h }
}

/// パッチの並び。判定側と描画側で同じ座標を使うため 1 か所に固める。
enum MainProbe {
    static let pw: Float = 120
    static let ph: Float = 80
    static let top: Float = 120

    static func slot(_ i: Int) -> Patch {
        Patch(x: 30 + Float(i) * 128, y: top, w: pw, h: ph)
    }

    static let blendA1 = slot(0)
    static let blendA0 = slot(1)
    static let gradV = slot(2)
    static let gradH = slot(3)
    static let gradD = slot(4)
    static let radial = slot(5)
    static let radialSeg0 = slot(6)
    static let vtxColor = slot(7)
    static let pushPop = slot(8)
    /// フレームを跨いだ漏れを見るための 1 枚（次のフレームで描く）。
    static let leak = Patch(x: 30, y: top + ph + 40, w: pw, h: ph)

    /// グラデーションの両端色。中点が平均になるかを見るので、混ざって別物になる 2 色にする。
    static let gradA = Color(r: 1, g: 0, b: 0)
    static let gradB = Color(r: 0, g: 0, b: 1)
    /// 放射グラデーションの内外。
    static let radInner = Color(r: 1, g: 1, b: 0)
    static let radOuter = Color(r: 0, g: 0.4, b: 1)
}

extension Sketch0816Gamut {

    // MARK: - 描く（フレーム 1）

    /// メインキャンバスへ検査パッチを並べる。判定は同じフレームの `loadPixels()` 後。
    func drawMainProbes() {
        let base = Instrument.baseColor
        let src = Instrument.srcColor
        noStroke()
        rectMode(.corner)

        /// 下地を敷いてから mode で全面に重ねる定型（Swatch.over のメインキャンバス版）。
        func over(_ p: Patch, _ srcColor: Color, _ mode: BlendMode) {
            blendMode(.opaque)
            fill(base)
            rect(p.x, p.y, p.w, p.h)
            blendMode(mode)
            fill(srcColor)
            rect(p.x, p.y, p.w, p.h)
            blendMode(.alpha)
        }

        // R1: オフスクリーンと同じ合成をメインでも。α=1 と α=0。
        over(MainProbe.blendA1, src, .multiply)
        over(MainProbe.blendA0, src.withAlpha(0), .multiply)

        // R2〜R4: グラデーション（Graphics には無いので必ずここ）。
        blendMode(.opaque)
        let gv = MainProbe.gradV
        linearGradient(gv.x, gv.y, gv.w, gv.h, MainProbe.gradA, MainProbe.gradB, axis: .vertical)
        let gh = MainProbe.gradH
        linearGradient(gh.x, gh.y, gh.w, gh.h, MainProbe.gradA, MainProbe.gradB, axis: .horizontal)
        let gd = MainProbe.gradD
        linearGradient(gd.x, gd.y, gd.w, gd.h, MainProbe.gradA, MainProbe.gradB, axis: .diagonal)

        // R5・R6: 放射グラデーション。既定のセグメント数と、退化した segments=0。
        let rd = MainProbe.radial
        fill(Color.black)
        rect(rd.x, rd.y, rd.w, rd.h)
        radialGradient(rd.cx, rd.cy, rd.h / 2 - 2, MainProbe.radInner, MainProbe.radOuter)
        let r0 = MainProbe.radialSeg0
        fill(Color.black)
        rect(r0.x, r0.y, r0.w, r0.h)
        radialGradient(r0.cx, r0.cy, r0.h / 2 - 2, MainProbe.radInner, MainProbe.radOuter,
                       segments: 0)

        // R7: 色付き頂点。四隅に別の色を置いて中心の補間を見る。
        let vt = MainProbe.vtxColor
        beginShape()
        vertex(vt.x, vt.y, Color(r: 1, g: 0, b: 0))
        vertex(vt.right, vt.y, Color(r: 0, g: 1, b: 0))
        vertex(vt.right, vt.bottom, Color(r: 0, g: 0, b: 1))
        vertex(vt.x, vt.bottom, Color(r: 1, g: 1, b: 1))
        endShape(.close)

        // R8: pushStyle / popStyle が blendMode を戻すか。
        //     戻るなら .alpha のまま（= src がそのまま）、戻らないなら multiply の結果になる。
        let pp = MainProbe.pushPop
        blendMode(.opaque)
        fill(base)
        rect(pp.x, pp.y, pp.w, pp.h)
        blendMode(.alpha)
        pushStyle()
        blendMode(.multiply)
        popStyle()
        fill(src)
        rect(pp.x, pp.y, pp.w, pp.h)
        blendMode(.alpha)

        // R9 の仕込み: このフレームを **multiply のまま終える**。
        // 次フレームの冒頭で既定へ戻っているかを見る。
        blendMode(.multiply)
    }

    /// 描いたパッチを読んで判定する（同じフレームで `loadPixels()` 済みであること）。
    func judgeMainProbes(_ r: MainReader) -> [Verdict] {
        var out: [Verdict] = []
        let base = Instrument.baseColor
        let src = Instrument.srcColor

        // R0: パックの並びを実測で確かめる。ここがずれていたら以降は全部信用できない。
        do {
            let p = MainProbe.gradV
            let top = r.rgba(p.cx, p.y + 3)
            let ok = top.r > 200 && top.g < 60 && top.b < 60
            out.append(Verdict(
                id: "R0.packing", passed: ok,
                detail: "純赤のはずの位置を読むと \(top.text)（(A<<24)|(R<<16)|(G<<8)|B と解釈）"))
        }

        // R1: メインキャンバスの合成が、オフスクリーンと同じ式に従うか。
        do {
            let dst = RGBA8(unit: base.r, base.g, base.b)
            let got = r.rgba(MainProbe.blendA1.cx, MainProbe.blendA1.cy)
            let want = Instrument.expected(mode: .multiply, dst: dst, src: src, alpha: 1)
            let (ok, text) = compare("α=1", got, want, tol: 3)
            out.append(Verdict(id: "R1.mainBlend.a1", passed: ok,
                               detail: "メインキャンバスでも multiply は src·dst か / \(text)"))
        }

        // R2: **本命のメイン版**。α=0 の src を重ねて下地のままか。
        //     オフスクリーン（A0.multiply）と同じ結果なら、経路ではなく仕様の問題。
        do {
            let dst = RGBA8(unit: base.r, base.g, base.b)
            let got = r.rgba(MainProbe.blendA0.cx, MainProbe.blendA0.cy)
            let (ok, text) = compare("α=0", got, dst, tol: 3)
            out.append(Verdict(
                id: "R2.mainBlend.a0", passed: ok,
                detail: "透明な src を multiply で重ねて下地のままか（オフスクリーンと同じか）/ \(text)"))
        }

        /// グラデーションの位置 t（0…1）での期待色。
        ///
        /// **端から数 px 内側を読めば、そこはもう補間の途中**。端点色を期待すると
        /// 「245 なのに 255 を期待」という自分の検査バグになる（実際に一度踏んだ）ので、
        /// 読む位置の t から期待値を出す。
        func gradExpected(_ t: Float) -> RGBA8 {
            let c = MainProbe.gradA.lerp(to: MainProbe.gradB, t: t)
            return RGBA8(unit: c.r, c.g, c.b)
        }

        // R3: linearGradient(.vertical)。位置 t の色が lerp(c1, c2, t) に乗っているか。
        do {
            let p = MainProbe.gradV
            var lines: [String] = []
            var ok = true
            for t in [Float(0.1), 0.5, 0.9] {
                let got = r.rgba(p.cx, p.y + p.h * t)
                let want = gradExpected(t)
                ok = ok && got.rgbNear(want, tol: 6)
                lines.append("t=\(Approx.f(t, 1)) 実測=\(got.rgbText) 期待=\(want.rgbText)")
            }
            out.append(Verdict(id: "R3.linearGradientVertical", passed: ok,
                               detail: "上から下へ線形か / " + lines.joined(separator: " / ")))
        }

        // R4: linearGradient(.horizontal)。左から右へ同じ線形性。
        do {
            let p = MainProbe.gradH
            var lines: [String] = []
            var ok = true
            for t in [Float(0.1), 0.5, 0.9] {
                let got = r.rgba(p.x + p.w * t, p.cy)
                let want = gradExpected(t)
                ok = ok && got.rgbNear(want, tol: 6)
                lines.append("t=\(Approx.f(t, 1)) 実測=\(got.rgbText) 期待=\(want.rgbText)")
            }
            out.append(Verdict(id: "R4.linearGradientHorizontal", passed: ok,
                               detail: "左から右へ線形か / " + lines.joined(separator: " / ")))
        }

        // R5: linearGradient(.diagonal) の実体は **四隅補間**。
        //     実装は tl=c1・br=c2 に対して **tr と bl の両方へ中点色**を置いているだけなので、
        //     「左上から右下へ」の等値線は対角線に垂直にならず、右上と左下が同色になる。
        //     doc は「左上から右下へ斜めにグラデーションを適用」としか書いていないので、
        //     ここは**実測を記録に残す**（tr ≒ bl であることを性質として固定する）。
        do {
            let p = MainProbe.gradD
            let inset: Float = 4
            let tl = r.rgba(p.x + inset, p.y + inset)
            let tr = r.rgba(p.right - inset, p.y + inset)
            let bl = r.rgba(p.x + inset, p.bottom - inset)
            let br = r.rgba(p.right - inset, p.bottom - inset)
            // 右上と左下が互いに近い（= 四隅補間）／左上は c1 寄り／右下は c2 寄り。
            let symmetric = tr.rgbNear(bl, tol: 8)
            let ends = tl.r > tl.b && br.b > br.r
            out.append(Verdict(
                id: "R5.diagonalIsCornerInterpolation", passed: symmetric && ends,
                detail: "四隅 tl=\(tl.rgbText) tr=\(tr.rgbText) bl=\(bl.rgbText) br=\(br.rgbText)"
                    + " / tr≒bl=\(symmetric)（右上と左下が同色 = 四隅補間であって"
                    + "対角に垂直な等値線ではない）"))
        }

        // R6: radialGradient の中心は innerColor。
        do {
            let p = MainProbe.radial
            let center = r.rgba(p.cx, p.cy)
            let want = RGBA8(255, 255, 0)
            let (ok, text) = compare("中心", center, want, tol: 6)
            out.append(Verdict(id: "R6.radialGradientCenter", passed: ok,
                               detail: "中心は innerColor か / \(text)"))
        }

        // R7: segments=0 は `max(segments, 6)` でクランプされるはず。
        //     クランプされていれば六角形が描かれ、中心は innerColor のまま。
        do {
            let p = MainProbe.radialSeg0
            let center = r.rgba(p.cx, p.cy)
            let want = RGBA8(255, 255, 0)
            let (ok, text) = compare("中心", center, want, tol: 6)
            out.append(Verdict(
                id: "R7.radialGradientSegmentsClamped", passed: ok,
                detail: "segments=0 でも 6 にクランプされて描かれるか / \(text)"))
        }

        // R8: 色付き頂点の補間。四隅が赤・緑・青・白の四角形の中心を読む。
        //
        // 四角形は 2 つの三角形に割られるので、**中心はどちらかの対角線上に乗る**。
        // つまり中心色は「赤と青の中点」か「緑と白の中点」のどちらかであって、
        // 4 色の平均にはならない（ここを平均だと決めつけて一度誤判定した）。
        do {
            let p = MainProbe.vtxColor
            let center = r.rgba(p.cx, p.cy)
            let redBlue = RGBA8(128, 0, 128)      // 対角線が tl–br のとき
            let greenWhite = RGBA8(128, 255, 128) // 対角線が tr–bl のとき
            let onRedBlue = center.rgbNear(redBlue, tol: 6)
            let onGreenWhite = center.rgbNear(greenWhite, tol: 6)
            out.append(Verdict(
                id: "R8.vertexColorInterpolates", passed: onRedBlue || onGreenWhite,
                detail: "四隅を赤/緑/青/白にした中心=\(center.rgbText) / "
                    + "対角線 tl–br なら \(redBlue.rgbText)、tr–bl なら \(greenWhite.rgbText)"
                    + "（実際は \(onGreenWhite ? "tr–bl" : onRedBlue ? "tl–br" : "どちらでもない")）"))
        }

        // R9: pushStyle / popStyle が blendMode を戻すか。
        //     戻るなら .alpha のままなので不透明 src がそのまま出る。
        do {
            let p = MainProbe.pushPop
            let got = r.rgba(p.cx, p.cy)
            let asAlpha = RGBA8(unit: src.r, src.g, src.b)
            let dst = RGBA8(unit: base.r, base.g, base.b)
            let asMultiply = Instrument.expected(mode: .multiply, dst: dst, src: src, alpha: 1)
            let restored = got.rgbNear(asAlpha, tol: 3)
            let leaked = got.rgbNear(asMultiply, tol: 3)
            out.append(Verdict(
                id: "R9.pushPopRestoresBlendMode", passed: restored,
                detail: "実測=\(got.rgbText) / 戻っていれば \(asAlpha.rgbText)、"
                    + "popStyle が blendMode を持たなければ \(asMultiply.rgbText)"
                    + "（multiply のまま漏れた=\(leaked)）"))
        }

        return out
    }

    // MARK: - フレームを跨ぐ検査

    /// 前フレームを `.multiply` のまま終えた直後に、既定の合成で 1 枚描く。
    func drawFrameLeakProbe() {
        let p = MainProbe.leak
        noStroke()
        rectMode(.corner)
        // ここでは **blendMode を触らない**。前フレームの設定が残っていれば multiply になる。
        fill(Instrument.baseColor)
        rect(p.x, p.y, p.w, p.h)
        fill(Instrument.srcColor)
        rect(p.x, p.y, p.w, p.h)
    }

    /// - Parameter backdrop: 前フレームで leak 位置に写っていた色（実測）。
    ///   状態が持ち越されていると**下地の矩形まで multiply される**ので、
    ///   期待値はこの色から 2 段重ねて出す。ここを「下地は普通に描かれる」と決めつけて
    ///   一度誤った期待を立てた。
    func judgeFrameLeak(_ r: MainReader, backdrop: RGBA8) -> [Verdict] {
        let p = MainProbe.leak
        let got = r.rgba(p.cx, p.cy)

        // 持ち越された場合: backdrop × base × src の 2 段重ね。
        let step1 = Instrument.expected(mode: .multiply, dst: backdrop,
                                        src: Instrument.baseColor, alpha: 1)
        let persisted = Instrument.expected(mode: .multiply, dst: step1,
                                            src: Instrument.srcColor, alpha: 1)
        // 毎フレーム既定へ戻る場合: 下地が不透明に置かれ、src が alpha で乗る。
        let reset = RGBA8(unit: Instrument.srcColor.r, Instrument.srcColor.g, Instrument.srcColor.b)

        let isPersisted = got.rgbNear(persisted, tol: 3)
        let isReset = got.rgbNear(reset, tol: 3)

        // **持ち越すのが期待**。fill / stroke / rectMode と同じくスタイル状態は永続する、
        // という Processing 互換の状態モデルに揃っているかを見る。
        return [Verdict(
            id: "R10.blendModePersistsAcrossFrames", passed: isPersisted,
            detail: "前フレームを multiply のまま終えた次のフレーム: 実測=\(got.rgbText)"
                + " / 持ち越すなら \(persisted.rgbText)（backdrop \(backdrop.rgbText) から 2 段重ね）"
                + "、毎フレーム戻るなら \(reset.rgbText)"
                + " → 持ち越し=\(isPersisted) リセット=\(isReset)"
                + "（fill などと同じで永続。draw() の冒頭で明示的に戻す必要がある）")]
    }
}
