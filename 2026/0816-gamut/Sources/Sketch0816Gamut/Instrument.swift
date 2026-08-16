import Foundation
import metaphor

// 決定論的な検査群。
//
// 描画も実時計も使わない — オフスクリーン 1 枚に合成して読み戻すだけなので、実行のたびに
// 同じ数値が出る。最初のフレームで 1 回だけ回し、結果を frame.json の `custom`（`check.<ID>`）と
// 標準出力へ出す。
//
// **期待値の作り方が この作品の肝**。
//
//   1. `blendFn` は「α を含まない混ぜ方」。実装（PipelineFactory.swift の BlendMode.apply(to:) と
//      MetaphorCanvas2D.metal）から読み取った式をそのまま置く
//   2. α を含む合成は `mix(dst, blendFn(dst, src), α)` を期待とする。
//      これは metaphor 自身が difference / exclusion のシェーダーで採っている意味論なので、
//      **同じ意味論をすべてのモードに要求する**という立場（B 系は α=1、A 系が α<1）
//
// 下地は実測して dst に使う。指定した Float から計算すると 8bit 量子化のぶんずれる。

@MainActor
enum Instrument {

    /// 検査に使う下地と重ねの色。
    ///
    /// **どの 2 モードも結果が違う値になる**ように選んである（取り違えを検出するため）。
    /// src の g だけ base より大きいので、subtract は g でクランプし、difference とは別の値になる。
    static let baseColor = Color(r: 0.40, g: 0.30, b: 0.20)
    static let srcColor = Color(r: 0.25, g: 0.55, b: 0.15)

    static func runAll(_ sw: Swatch) -> [Verdict] {
        var out: [Verdict] = []
        out.append(sw.calibrate())
        out += blendFormulas(sw)
        out += alphaSemantics(sw)
        out += algebra(sw)
        out += paths(sw)
        out += colorApi()
        return out
    }

    /// 色の反転（ド・モルガン双対の検査に使う）。
    static func invert(_ c: Color) -> Color {
        Color(r: 1 - c.r, g: 1 - c.g, b: 1 - c.b, a: c.a)
    }

    // MARK: - モードの定義（実装から読み取った式）

    /// α を含まない「混ぜ方」本体。チャンネルごとに (dst, src) → 結果。
    static func blendFn(_ mode: BlendMode) -> (Float, Float) -> Float {
        switch mode {
        case .opaque, .alpha: return { _, s in s }
        case .additive: return { d, s in min(1, s + d) }
        case .multiply: return { d, s in s * d }
        case .screen: return { d, s in s + d - s * d }
        case .subtract: return { d, s in max(0, d - s) }
        case .lightest: return { d, s in max(s, d) }
        case .darkest: return { d, s in min(s, d) }
        case .difference: return { d, s in abs(s - d) }
        case .exclusion: return { d, s in s + d - 2 * s * d }
        }
    }

    /// モード名と、期待式の説明（issue にそのまま貼れる形）。
    ///
    /// 作品側（HUD）からも引くので nonisolated。純粋な写像なので隔離は要らない。
    nonisolated static func label(_ mode: BlendMode) -> (name: String, formula: String) {
        switch mode {
        case .opaque: return ("opaque", "src（ブレンド無効）")
        case .alpha: return ("alpha", "src·a + dst·(1−a)")
        case .additive: return ("additive", "min(1, src + dst)")
        case .multiply: return ("multiply", "src·dst")
        case .screen: return ("screen", "src + dst − src·dst")
        case .subtract: return ("subtract", "max(0, dst − src)")
        case .lightest: return ("lightest", "max(src, dst)")
        case .darkest: return ("darkest", "min(src, dst)")
        case .difference: return ("difference", "|src − dst|")
        case .exclusion: return ("exclusion", "src + dst − 2·src·dst")
        }
    }

    /// 安定した順で回すための並び（`allCases` の順に依存したくない）。
    static let modes: [BlendMode] = [
        .opaque, .alpha, .additive, .multiply, .screen,
        .subtract, .lightest, .darkest, .difference, .exclusion,
    ]

    /// 実測の dst と指定した src から、α 込みの期待色を作る。
    ///
    /// `mix(dst, blend, α)` — α は「混ぜ方をどれだけ効かせるか」。
    static func expected(mode: BlendMode, dst: RGBA8, src: Color, alpha: Float) -> RGBA8 {
        let fn = blendFn(mode)
        func ch(_ d8: Int, _ s: Float) -> Float {
            let d = Float(d8) / 255
            let blended = fn(d, s)
            return d + (blended - d) * alpha
        }
        return RGBA8(unit: ch(dst.r, src.r), ch(dst.g, src.g), ch(dst.b, src.b))
    }

    // MARK: - B 系: 10 モードの合成式（α = 1）

    static func blendFormulas(_ sw: Swatch) -> [Verdict] {
        let dst = sw.baseOnly(baseColor)
        var out: [Verdict] = [
            Verdict(id: "B1.baseline", passed: dst.rgbNear(RGBA8(102, 77, 51), tol: 2),
                    detail: "下地の実測=\(dst.rgbText) 期待=rgb(102,77,51)（以降の dst はこの実測を使う）")
        ]

        for mode in modes {
            let (name, formula) = label(mode)
            let got = sw.over(base: baseColor, src: srcColor, mode: mode)
            let want = expected(mode: mode, dst: dst, src: srcColor, alpha: 1)
            let (ok, text) = compare("α=1", got, want, tol: 2)
            out.append(Verdict(id: "B.\(name)", passed: ok, detail: "\(formula) / \(text)"))
        }
        return out
    }

    // MARK: - A 系: α との組み合わせ（本命）

    /// α を下げたときに「混ぜ方の効き」が比例して減るか。
    ///
    /// 実装を読む限り multiply / screen / lightest / darkest は固定関数ブレンドの係数に
    /// src.a が入らないので、**α を下げても効きが減らない**はず。ここが落ちるなら、
    /// 同じライブラリの difference / exclusion（`mix(dst, blended, src.a)`）と意味論が食い違う。
    static func alphaSemantics(_ sw: Swatch) -> [Verdict] {
        let dst = sw.baseOnly(baseColor)
        var out: [Verdict] = []

        // A1: α = 0。**完全に透明な src は下地を変えないこと**。
        // opaque はブレンド無効なので上書きが仕様どおり。除外する。
        for mode in modes where mode != .opaque {
            let (name, _) = label(mode)
            let src = srcColor.withAlpha(0)
            let got = sw.over(base: baseColor, src: src, mode: mode)
            let (ok, text) = compare("α=0", got, dst, tol: 2)
            out.append(Verdict(
                id: "A0.\(name)", passed: ok,
                detail: "透明な src を重ねて下地のままか / \(text)"))
        }

        // A2: α = 0.5。効きが半分になるか。
        for mode in modes where mode != .opaque {
            let (name, formula) = label(mode)
            let src = srcColor.withAlpha(0.5)
            let got = sw.over(base: baseColor, src: src, mode: mode)
            let want = expected(mode: mode, dst: dst, src: srcColor, alpha: 0.5)
            let (ok, text) = compare("α=0.5", got, want, tol: 2)
            out.append(Verdict(
                id: "A5.\(name)", passed: ok,
                detail: "mix(dst, \(formula), 0.5) / \(text)"))
        }

        // A3: **合成結果のアルファ**。不透明な下地に何を重ねても、結果は不透明であるべき。
        //
        // multiply のアルファ係数は (source=.destinationAlpha, destination=.zero) なので
        // `result.a = src.a × dst.a`。α=0 の src を重ねると**下地の不透明性まで 0 になり、
        // キャンバスに穴が開く**。作品側で α を 0 まで絞ったとき、絵の具の卓が「消える」
        // のではなく真っ白な塊になったのがこれ（RGB だけ見ていたら気付かなかった）。
        //
        // 同じ問題は alpha モードでは既に手当てされている（PipelineFactory のコメントに
        // 「src.a が二乗されて出力テクスチャの α が極端に減衰し、Syphon 等でアルファ合成する
        // 用途で透明と区別がつかなくなる」とあり、sourceAlphaBlendFactor は .one）。
        // opaque はブレンド無効（src をそのまま書く）が仕様なので、α もそのまま入る。
        // ここでは「合成した結果」を問うので除外する（A9 が別に見ている）。
        for mode in modes where mode != .opaque {
            let (name, _) = label(mode)
            let got = sw.over(base: baseColor, src: srcColor.withAlpha(0), mode: mode)
            let ok = got.a >= 250
            out.append(Verdict(
                id: "A3.opaqueResult.\(name)", passed: ok,
                detail: "不透明な下地に α=0 を重ねた結果のアルファ 実測=\(got.a) 期待=255"
                    + "（色=\(got.rgbText)）"))
        }

        // A4: 半透明を重ねたときも、不透明な下地の上なら結果は不透明であるべき。
        for mode in modes where mode != .opaque {
            let (name, _) = label(mode)
            let got = sw.over(base: baseColor, src: srcColor.withAlpha(0.5), mode: mode)
            let ok = got.a >= 250
            out.append(Verdict(
                id: "A4.opaqueResult50.\(name)", passed: ok,
                detail: "不透明な下地に α=0.5 を重ねた結果のアルファ 実測=\(got.a) 期待=255"
                    + "（色=\(got.rgbText)）"))
        }

        // A2: **完全に不透明**な色を重ねた結果も、当然に不透明であるべき。
        //
        // subtract は alpha も reverseSubtract なので `result.a = dst.a − src.a`。
        // α=1 の色を重ねると 1 − 1 = 0 になり、**不透明な色で塗ったのに完全に透明**になる。
        // α=0 / 0.5 だけを見ていたときは気付かなかった（α=0 では 1−0=1 で PASS してしまう）。
        for mode in modes where mode != .opaque {
            let (name, _) = label(mode)
            let got = sw.over(base: baseColor, src: srcColor.withAlpha(1), mode: mode)
            let ok = got.a >= 250
            out.append(Verdict(
                id: "A2.opaqueResult100.\(name)", passed: ok,
                detail: "不透明な下地に α=1 を重ねた結果のアルファ 実測=\(got.a) 期待=255"
                    + "（色=\(got.rgbText)）"))
        }

        // A9: opaque は α に関わらず src で上書きするか（仕様の確認。落ちない想定）。
        do {
            let got = sw.over(base: baseColor, src: srcColor.withAlpha(0), mode: .opaque)
            let want = RGBA8(unit: srcColor.r, srcColor.g, srcColor.b)
            let (ok, text) = compare("α=0 でも上書き", got, want, tol: 2)
            out.append(Verdict(id: "A9.opaqueIgnoresAlpha", passed: ok,
                               detail: "ブレンド無効なので α によらず src / \(text)"))
        }
        return out
    }

    // MARK: - L 系: 光と絵の具の代数（作品の主題そのもの）

    static func algebra(_ sw: Swatch) -> [Verdict] {
        var out: [Verdict] = []

        let red = Color(r: 1, g: 0, b: 0)
        let green = Color(r: 0, g: 1, b: 0)
        let blue = Color(r: 0, g: 0, b: 1)
        let cyan = Color(r: 0, g: 1, b: 1)
        let magenta = Color(r: 1, g: 0, b: 1)
        let yellow = Color(r: 1, g: 1, b: 0)

        // L1: 光の恒等。暗闇に R+G+B を加算で重ねると白。
        do {
            let got = sw.stack(base: .black, srcs: [red, green, blue], mode: .additive)
            let (ok, text) = compare("R+G+B", got, RGBA8(255, 255, 255), tol: 2)
            out.append(Verdict(id: "L1.additiveIdentity", passed: ok,
                               detail: "光の恒等: 暗闇に 3 原色を加算すると白 / \(text)"))
        }

        // L2: 絵の具の恒等。白紙に C×M×Y を乗算で重ねると黒。
        do {
            let got = sw.stack(base: .white, srcs: [cyan, magenta, yellow], mode: .multiply)
            let (ok, text) = compare("C×M×Y", got, RGBA8(0, 0, 0), tol: 2)
            out.append(Verdict(id: "L2.subtractiveIdentity", passed: ok,
                               detail: "絵の具の恒等: 白紙に 3 原色を乗算すると黒 / \(text)"))
        }

        // L3: ド・モルガン双対。screen(d,s) == 1 − multiply(1−d, 1−s)。
        //     光の混色と絵の具の混色が裏返しの関係にあることの表明。
        do {
            let s = sw.over(base: baseColor, src: srcColor, mode: .screen)
            let m = sw.over(base: invert(baseColor), src: invert(srcColor), mode: .multiply)
            let dual = RGBA8(255 - m.r, 255 - m.g, 255 - m.b)
            let (ok, text) = compare("screen vs 1−multiply(反転)", s, dual, tol: 2)
            out.append(Verdict(id: "L3.deMorgan", passed: ok,
                               detail: "screen(d,s) == 1 − multiply(1−d,1−s) / \(text)"))
        }

        // L4: 重ねる順を入れ替えても変わらないモード。
        //     subtract も「複数回の減算」は順不同（d−a−b == d−b−a）なのでここに入る。
        //     クランプで潰れると差が消えて検査にならないので、床にも天井にも当たらない色を使う。
        do {
            let base = Color(r: 0.90, g: 0.85, b: 0.80)
            let a = Color(r: 0.20, g: 0.15, b: 0.10)
            let b = Color(r: 0.30, g: 0.25, b: 0.20)
            for mode in [BlendMode.additive, .multiply, .screen, .lightest, .darkest,
                         .exclusion, .subtract] {
                let (name, _) = label(mode)
                let ab = sw.stack(base: base, srcs: [a, b], mode: mode)
                let ba = sw.stack(base: base, srcs: [b, a], mode: mode)
                let (ok, text) = compare("順序 AB vs BA", ab, ba, tol: 2)
                out.append(Verdict(id: "L4.commutative.\(name)", passed: ok,
                                   detail: "重ねる順を入れ替えても同じか / \(text)"))
            }
        }

        // L5a: difference は**重ねる順で変わる**（|b − |a − d|| ≠ |a − |b − d||）。
        //      3 原色のような極端な色だと偶然一致してしまうので中間調で当てる。
        do {
            let base = Color(gray: 0.5)
            let a = Color(gray: 0.2), b = Color(gray: 0.9)
            let ab = sw.stack(base: base, srcs: [a, b], mode: .difference)
            let ba = sw.stack(base: base, srcs: [b, a], mode: .difference)
            let differs = !ab.rgbNear(ba, tol: 2)
            out.append(Verdict(
                id: "L5a.differenceOrderMatters", passed: differs,
                detail: "重ねる順で変わるはず（|b−|a−d|| ≠ |a−|b−d||）/ AB=\(ab.rgbText) BA=\(ba.rgbText)"
                    + " 差=\(ab.rgbDistance(to: ba))"))
        }

        // L5b: subtract は **dst と src の役割**が非対称（dst − src であって src − dst ではない）。
        do {
            let a = Color(r: 0.7, g: 0.6, b: 0.5)
            let b = Color(r: 0.3, g: 0.2, b: 0.1)
            let ab = sw.over(base: a, src: b, mode: .subtract)
            let ba = sw.over(base: b, src: a, mode: .subtract)
            let differs = !ab.rgbNear(ba, tol: 2)
            out.append(Verdict(
                id: "L5b.subtractIsOriented", passed: differs,
                detail: "下地と重ねを入れ替えると変わるはず（dst−src）/ A下地=\(ab.rgbText)"
                    + " B下地=\(ba.rgbText) 差=\(ab.rgbDistance(to: ba))"))
        }

        // L5c: difference は **dst と src の役割**が対称（|dst − src| == |src − dst|）。
        do {
            let a = Color(r: 0.7, g: 0.6, b: 0.5)
            let b = Color(r: 0.3, g: 0.2, b: 0.1)
            let ab = sw.over(base: a, src: b, mode: .difference)
            let ba = sw.over(base: b, src: a, mode: .difference)
            let (ok, text) = compare("下地と重ねを入替", ab, ba, tol: 2)
            out.append(Verdict(id: "L5c.differenceIsSymmetric", passed: ok,
                               detail: "|dst−src| == |src−dst| / \(text)"))
        }

        // L6: max / min は冪等。同じ色を 2 度重ねても 1 度と同じ。
        for mode in [BlendMode.lightest, .darkest] {
            let (name, _) = label(mode)
            let once = sw.stack(base: baseColor, srcs: [srcColor], mode: mode)
            let twice = sw.stack(base: baseColor, srcs: [srcColor, srcColor], mode: mode)
            let (ok, text) = compare("1 回 vs 2 回", twice, once, tol: 2)
            out.append(Verdict(id: "L6.idempotent.\(name)", passed: ok,
                               detail: "同じ色を重ね直しても変わらないか / \(text)"))
        }

        // L7: 加算の天井。1 を超えたら 1 で止まる（光は白より明るくならない）。
        do {
            let base = Color(r: 0.8, g: 0.3, b: 0.2)
            let src = Color(r: 0.5, g: 0.2, b: 0.1)
            let dst = sw.baseOnly(base)
            let got = sw.over(base: base, src: src, mode: .additive)
            let want = expected(mode: .additive, dst: dst, src: src, alpha: 1)
            let (ok, text) = compare("r が飽和", got, want, tol: 2)
            out.append(Verdict(id: "L7.additiveSaturates", passed: ok,
                               detail: "0.8+0.5 は 1 で止まる / \(text)"))
        }

        // L8: 減算の床。0 を下回ったら 0 で止まる（絵の具は黒より暗くならない）。
        do {
            let base = Color(r: 0.3, g: 0.5, b: 0.7)
            let src = Color(r: 0.5, g: 0.2, b: 0.1)
            let dst = sw.baseOnly(base)
            let got = sw.over(base: base, src: src, mode: .subtract)
            let want = expected(mode: .subtract, dst: dst, src: src, alpha: 1)
            let (ok, text) = compare("r が床", got, want, tol: 2)
            out.append(Verdict(id: "L8.subtractClampsAtZero", passed: ok,
                               detail: "0.3−0.5 は 0 で止まる / \(text)"))
        }

        return out
    }

    // MARK: - P 系: 描画経路の差

    /// 同じ色・同じモードを違う描き方で置いて、`rect` の結果と一致するか。
    ///
    /// difference / exclusion だけで 4 系統のシェーダーがある（Canvas2D.swift の
    /// 通常 / textured / instanced / massive）ので、**経路が変われば実装も変わる**。
    /// α=0 の扱いが経路によって割れていないかもここで見る。
    static func paths(_ sw: Swatch) -> [Verdict] {
        var out: [Verdict] = []
        let fw = Float(sw.w), fh = Float(sw.h)

        /// 中心を覆う図形を、経路ごとに 1 つずつ。色は `fill` で決まる経路と、
        /// インスタンス側が持つ経路（`circles`）があるので、両方へ同じ色を渡せる形にする。
        let drawers: [(String, (Graphics, Color) -> Void)] = [
            ("circle", { g, _ in g.circle(fw / 2, fh / 2, max(fw, fh) * 1.5) }),
            ("triangle", { g, _ in g.triangle(-fw, -fh, fw * 2, -fh, fw / 2, fh * 3) }),
            ("quad", { g, _ in g.quad(0, 0, fw, 0, fw, fh, 0, fh) }),
            ("shape", { g, _ in
                g.beginShape()
                g.vertex(0, 0); g.vertex(fw, 0); g.vertex(fw, fh); g.vertex(0, fh)
                g.endShape(.close)
            }),
            ("circles", { g, c in
                g.circles([CircleInstance(x: fw / 2, y: fh / 2,
                                          diameter: max(fw, fh) * 1.5, color: c)])
            }),
        ]

        // 各経路 × (α=1, α=0)。基準は rect。
        for (pathName, body) in drawers {
            for alpha in [Float(1), Float(0)] {
                let mode = BlendMode.multiply
                let src = srcColor.withAlpha(alpha)
                let reference = sw.over(base: baseColor, src: src, mode: mode)
                sw.render { g in
                    g.noStroke()
                    g.rectMode(.corner)
                    g.blendMode(.opaque)
                    g.fill(baseColor)
                    g.rect(0, 0, fw, fh)
                    g.blendMode(mode)
                    g.fill(src)
                    body(g, src)
                    g.blendMode(.alpha)
                }
                let got = sw.center()
                let (ok, text) = compare("α=\(Approx.f(alpha, 1))", got, reference, tol: 2)
                // α=0 の側は「rect と一致 = 経路によらず同じ挙動」を意味するだけで、
                // その挙動が正しいかは A0 系が別に判定する（A0.multiply は落ちている）。
                let note = alpha == 0 ? "（一致 = 経路によらず一貫、の意。正否は A0 系が見る）" : ""
                out.append(Verdict(
                    id: "P.\(pathName).multiply.a\(alpha == 1 ? "1" : "0")", passed: ok,
                    detail: "multiply を \(pathName) で描いて rect と一致するか / \(text)\(note)"))
            }
        }
        return out
    }

    // MARK: - G 系: 色を作る API（描画しない。純粋な数値）

    static func colorApi() -> [Verdict] {
        var out: [Verdict] = []

        func near(_ a: Color, _ b: Color, _ tol: Float = 1e-4) -> Bool {
            Approx.eq(a.r, b.r, tol) && Approx.eq(a.g, b.g, tol)
                && Approx.eq(a.b, b.b, tol) && Approx.eq(a.a, b.a, tol)
        }
        func text(_ c: Color) -> String {
            "(\(Approx.f(c.r, 3)), \(Approx.f(c.g, 3)), \(Approx.f(c.b, 3)), \(Approx.f(c.a, 3)))"
        }

        // G1: Color(hue:) の hue は **0…1 正規化**。colorMode(.hsb, 360, …) の hue とは
        //     スケールが違う（混同しやすい非対称なので明示的に固定する）。
        do {
            let h0 = Color(hue: 0, saturation: 1, brightness: 1)
            let red = Color(r: 1, g: 0, b: 0)
            let third = Color(hue: 1.0 / 3.0, saturation: 1, brightness: 1)
            let green = Color(r: 0, g: 1, b: 0)
            let ok = near(h0, red, 1e-3) && near(third, green, 1e-2)
            out.append(Verdict(
                id: "G1.hueIsUnitScale", passed: ok,
                detail: "hue=0 → \(text(h0)) 期待=純赤 / hue=1/3 → \(text(third)) 期待=純緑"
                    + "（**0…360 ではなく 0…1**）"))
        }

        // G2: 範囲外・負の hue は 1 周期で巻き戻る。
        do {
            let a = Color(hue: 1.0, saturation: 1, brightness: 1)      // = hue 0
            let b = Color(hue: -0.25, saturation: 1, brightness: 1)    // = hue 0.75
            let c = Color(hue: 0.75, saturation: 1, brightness: 1)
            let d = Color(hue: 2.5, saturation: 1, brightness: 1)      // = hue 0.5
            let e = Color(hue: 0.5, saturation: 1, brightness: 1)
            let ok = near(a, Color(r: 1, g: 0, b: 0), 1e-3) && near(b, c, 1e-3) && near(d, e, 1e-3)
            out.append(Verdict(
                id: "G2.hueWraps", passed: ok,
                detail: "hue=1.0 → \(text(a)) 期待=hue 0 / hue=−0.25 → \(text(b)) 期待=hue 0.75 の \(text(c))"
                    + " / hue=2.5 と hue=0.5 が一致=\(near(d, e, 1e-3))"))
        }

        // G3: 非有限な hue は 0 にフォールバックする（実装が明示的に防御している）。
        do {
            let nan = Color(hue: .nan, saturation: 1, brightness: 1)
            let ok = nan.r.isFinite && nan.g.isFinite && nan.b.isFinite
            out.append(Verdict(id: "G3.hueNonFinite", passed: ok,
                               detail: "hue=NaN → \(text(nan))（有限値へ落ちること）"))
        }

        // G4: lerp は t を 0…1 にクランプする（外挿しない）。
        do {
            let a = Color(r: 1, g: 0, b: 0, a: 1)
            let b = Color(r: 0, g: 0, b: 1, a: 0)
            let under = a.lerp(to: b, t: -1)
            let over = a.lerp(to: b, t: 2)
            let mid = a.lerp(to: b, t: 0.5)
            let ok = near(under, a) && near(over, b) && near(mid, Color(r: 0.5, g: 0, b: 0.5, a: 0.5))
            out.append(Verdict(
                id: "G4.lerpClamps", passed: ok,
                detail: "t=−1 → \(text(under)) 期待=始点 / t=2 → \(text(over)) 期待=終点 / t=0.5 → \(text(mid))"
                    + " 期待=(0.500, 0.000, 0.500, 0.500)（**α も補間される**）"))
        }

        // G5: interpolate は lerp と同じ結果か（2 つある入口が食い違わないこと）。
        do {
            let a = Color(r: 0.2, g: 0.4, b: 0.6, a: 0.8)
            let b = Color(r: 0.9, g: 0.1, b: 0.3, a: 0.2)
            let viaMethod = a.lerp(to: b, t: 0.35)
            let viaStatic = Color.interpolate(from: a, to: b, t: 0.35)
            let viaFree = lerpColor(a, b, 0.35)
            let ok = near(viaMethod, viaStatic) && near(viaMethod, viaFree)
            out.append(Verdict(
                id: "G5.interpolateMatchesLerp", passed: ok,
                detail: "lerp=\(text(viaMethod)) / interpolate=\(text(viaStatic)) / lerpColor=\(text(viaFree))"))
        }

        // G6: withAlpha は RGB を保ったまま α だけ差し替える。
        do {
            let a = Color(r: 0.2, g: 0.4, b: 0.6, a: 0.8)
            let w = a.withAlpha(0.25)
            let ok = Approx.eq(w.r, a.r) && Approx.eq(w.g, a.g) && Approx.eq(w.b, a.b)
                && Approx.eq(w.a, 0.25)
            out.append(Verdict(id: "G6.withAlpha", passed: ok,
                               detail: "\(text(a)).withAlpha(0.25) → \(text(w))"))
        }

        return out
    }
}
